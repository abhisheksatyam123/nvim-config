--- text-analyzer/init.lua
--- Phase 1: rg-based async matching, large file mode, viewport-only extmarks.

local Filter = require("text-analyzer.filter")

local M = {}

-- ── State ────────────────────────────────────────────────────────

local buf_states = {}

-- ── Lazy-loaded Modules ─────────────────────────────────────────

local UI, Storage
local function get_ui()
  if not UI then UI = require("text-analyzer.ui") end
  return UI
end
local function get_storage()
  if not Storage then Storage = require("text-analyzer.storage") end
  return Storage
end

-- ── Configuration ─────────────────────────────────────────────────

M.config = {
  auto_load            = {},
  filter_dir           = nil,
  workspace_dir        = nil,
  enable_filetypes     = { "log", "txt" },
  lighten_buffers      = true,
  large_file_threshold = 50 * 1024 * 1024,  -- 50 MB; set to 0 to always use large-file mode
  context_lines        = 25,                 -- ±N lines loaded around a match (never the whole file)
  max_results          = 10000,              -- per-filter cap in large-file mode
}

-- ── Buffer Lightening ────────────────────────────────────────────

function M.lighten_buffer(bufnr)
  if not M.config.lighten_buffers then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    pcall(vim.lsp.buf_detach_client, bufnr, client.id)
  end
  vim.b[bufnr].ta_lightened = true
  pcall(vim.treesitter.stop, bufnr)
  pcall(vim.cmd, "NoMatchParen")
end

function M.unlighten_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.b[bufnr].ta_lightened = nil
end

-- ── Large File Helpers ────────────────────────────────────────────

--- Returns true if this buffer is in large-file mode (file NOT loaded into nvim).
function M.is_large_file(bufnr)
  return vim.b[bufnr] ~= nil and vim.b[bufnr].ta_large_file ~= nil
end

--- Returns the real filepath to search (handles both small and large file mode).
function M.get_filepath(bufnr)
  if M.is_large_file(bufnr) then
    return vim.b[bufnr].ta_large_file
  end
  return vim.api.nvim_buf_get_name(bufnr)
end

local function human_size(bytes)
  if bytes >= 1e9 then return string.format("%.1f GB", bytes / 1e9) end
  if bytes >= 1e6 then return string.format("%.1f MB", bytes / 1e6) end
  return string.format("%d KB", math.floor(bytes / 1024))
end

-- ── State Accessors ───────────────────────────────────────────────

function M.state(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not buf_states[bufnr] then
    buf_states[bufnr] = {
      filters          = {},
      enabled          = false,
      -- small-file visibility
      visibility       = {},   -- line_num → true  (has_include mode)
      excluded         = {},   -- line_num → true  (exclusion-only mode)
      has_include      = false,
      ns_id            = vim.api.nvim_create_namespace("text-analyzer-" .. bufnr),
      saved_folds      = nil,  -- full window fold snapshot
      -- large-file results
      results          = {},   -- array of { line_num, byte, filter, content }
      line_map         = {},   -- buf_line (1-indexed) → original file line_num
      byte_map         = {},   -- buf_line (1-indexed) → byte offset of match
      truncated        = false,
      search_jobs      = {},   -- active jobstart ids (for cancellation)
      match_gen        = 0,    -- generation token; stale job callbacks ignored
      empty_match      = false,-- include filters matched nothing (view not restricted)
      last_empty_notify = 0,   -- throttle empty-match notifications
    }
  end
  return buf_states[bufnr]
end

--- Stop all in-flight rg jobs for a buffer.
function M.cancel_search_jobs(bufnr)
  local st = buf_states[bufnr]
  if not st then return end
  for _, jid in ipairs(st.search_jobs or {}) do
    pcall(vim.fn.jobstop, jid)
  end
  st.search_jobs = {}
end

function M.clear_state(bufnr)
  M.cancel_search_jobs(bufnr)
  buf_states[bufnr] = nil
end

-- ── rg-based Async Matching ────────────────────────────────────────

--- Build rg argv. opts: { byte_offset=bool, max_count=number }
local function filter_to_rg_args(filter, filepath, opts)
  opts = opts or {}
  local args = { "rg", "--line-number", "--no-heading", "--color=never", "--max-columns", "2000" }
  if opts.byte_offset then table.insert(args, "--byte-offset") end
  if opts.max_count and opts.max_count > 0 then
    table.insert(args, "--max-count")
    table.insert(args, tostring(opts.max_count))
  end
  if not filter.case_sensitive then table.insert(args, "--ignore-case") end
  if filter.type == "literal"  then table.insert(args, "--fixed-strings") end
  table.insert(args, "--")
  table.insert(args, filter.pattern)
  table.insert(args, filepath)
  return args
end

local function _track_job(st, jid)
  if type(jid) == "number" and jid > 0 then
    table.insert(st.search_jobs, jid)
  end
end

local function _untrack_job(st, jid)
  if not st or not st.search_jobs then return end
  for i, id in ipairs(st.search_jobs) do
    if id == jid then
      table.remove(st.search_jobs, i)
      break
    end
  end
end

--- Match a single filter against the file using rg (async).
--- on_done() is called when rg exits. filter.match_cache is populated.
--- Stale callbacks from cancelled/superseded jobs are ignored.
function M.match_filter(filter, bufnr, on_done)
  local st = M.state(bufnr)
  local filepath = M.get_filepath(bufnr)
  filter._match_gen = (filter._match_gen or 0) + 1
  local gen = filter._match_gen
  filter.match_cache = {}
  filter._rg_error = nil

  local function finish()
    if filter._match_gen ~= gen then return end
    if on_done then on_done() end
  end

  if filepath == "" then
    finish()
    return
  end

  -- Graceful fallback: if rg is not installed, use Lua loop (small files only)
  if vim.fn.executable("rg") == 0 then
    if not M.is_large_file(bufnr) then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for i, line in ipairs(lines) do
        if filter:matches(line) then filter.match_cache[i] = true end
      end
    end
    finish()
    return
  end

  local args = filter_to_rg_args(filter, filepath)
  local jid

  jid = vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if filter._match_gen ~= gen or not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then
          local lnum = line:match("^(%d+):")
          if lnum then filter.match_cache[tonumber(lnum)] = true end
        end
      end
    end,
    on_stderr = function(_, data)
      if filter._match_gen ~= gen or not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then
          filter._rg_error = (filter._rg_error and (filter._rg_error .. "; ") or "") .. line
        end
      end
    end,
    on_exit = function(_, code)
      _untrack_job(st, jid)
      if filter._match_gen ~= gen then return end
      -- rg: 0 = matches, 1 = no matches, >=2 = error (bad regex, etc.)
      if code and code > 1 then
        filter.match_cache = {}
        filter._rg_error = filter._rg_error or ("rg exit " .. tostring(code))
        vim.schedule(function()
          vim.notify(
            string.format("TextAnalyzer: search failed for '%s' — %s", filter.pattern, filter._rg_error),
            vim.log.levels.WARN
          )
        end)
      end
      finish()
    end,
  })
  _track_job(st, jid)
end

--- Match all filters in parallel. Calls on_done() when every rg job finishes.
--- Cancels any previous in-flight searches first.
function M.match_all_filters(bufnr, on_done)
  local st = M.state(bufnr)
  M.cancel_search_jobs(bufnr)
  st.match_gen = (st.match_gen or 0) + 1
  local gen = st.match_gen

  if #st.filters == 0 then
    if on_done then on_done() end
    return
  end

  local pending = #st.filters
  local function check()
    pending = pending - 1
    if pending == 0 and st.match_gen == gen and on_done then
      on_done()
    end
  end
  for _, filter in ipairs(st.filters) do
    M.match_filter(filter, bufnr, check)
  end
end

--- Count how many lines a filter currently matches (from cache).
function M.filter_match_count(filter)
  local n = 0
  for _ in pairs(filter.match_cache or {}) do
    n = n + 1
  end
  return n
end

--- Count currently visible lines (small-file mode).
function M.visible_count(bufnr)
  local st = M.state(bufnr)
  if st.empty_match then return -1 end -- sentinel: unrestricted due to empty match
  if not st.has_include then
    return nil -- exclusion-only / show-all; unknown without scanning
  end
  local n = 0
  for _ in pairs(st.visibility or {}) do
    n = n + 1
  end
  return n
end

-- ── Visibility (small-file mode) ──────────────────────────────────

function M.recompute_visibility(bufnr)
  if M.is_large_file(bufnr) then return end
  local st = M.state(bufnr)
  local include, exclude, has_include = {}, {}, false
  local has_broken = false

  for _, filter in ipairs(st.filters) do
    if filter.enabled then
      if filter._rg_error then
        has_broken = true
      end
      local cache = filter.match_cache or {}
      if filter.invert then
        for ln in pairs(cache) do exclude[ln] = true end
      else
        -- Broken include patterns must not hide the whole buffer
        if not filter._rg_error then
          has_include = true
          for ln in pairs(cache) do include[ln] = true end
        end
      end
    end
  end

  st.empty_match = false

  if has_include then
    local visible, count = {}, 0
    for ln in pairs(include) do
      if not exclude[ln] then
        visible[ln] = true
        count = count + 1
      end
    end

    if count == 0 then
      -- Safety net: never leave the user in an all-folded / empty view.
      -- Keep filters active for editing, but do not restrict visibility.
      st.visibility  = {}
      st.excluded    = {}
      st.has_include = false
      st.empty_match = true

      local now = vim.loop.hrtime()
      if (now - (st.last_empty_notify or 0)) > 2e9 then -- 2s throttle
        st.last_empty_notify = now
        vim.schedule(function()
          vim.notify(
            "TextAnalyzer: 0 matches — showing full file. Toggle/edit filters (\\ta), reset (\\tr), or disable (\\tt).",
            vim.log.levels.WARN
          )
        end)
      end
    else
      st.visibility  = visible
      st.excluded    = {}
      st.has_include = true
    end
  else
    -- Exclusion-only (or no usable includes): store only excluded lines
    st.visibility  = {}
    st.excluded    = exclude
    st.has_include = false
    if has_broken then
      st.empty_match = true
    end
  end
end

-- ── Fold Management ───────────────────────────────────────────────

_G.text_analyzer_foldexpr = function(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  local st = buf_states[bufnr]
  if st and st.enabled then
    if st.has_include then
      return st.visibility[lnum] and "0" or "1"
    else
      return (st.excluded and st.excluded[lnum]) and "1" or "0"
    end
  end
  return "0"
end

_G.text_analyzer_foldtext = function()
  local lines = vim.v.foldend - vim.v.foldstart + 1
  return "╌  " .. lines .. " lines hidden  ╌"
end

function M.enable_folds(bufnr)
  if M.is_large_file(bufnr) then return end
  local st  = M.state(bufnr)
  if not st.enabled then return end
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then return end
  -- Snapshot once so repeated enable_folds calls don't overwrite with our expr folds
  if not st.saved_folds then
    st.saved_folds = {
      foldmethod  = vim.wo[win].foldmethod,
      foldexpr    = vim.wo[win].foldexpr,
      foldtext    = vim.wo[win].foldtext,
      foldlevel   = vim.wo[win].foldlevel,
      foldcolumn  = vim.wo[win].foldcolumn,
      foldenable  = vim.wo[win].foldenable,
      foldminlines = vim.wo[win].foldminlines,
    }
  end
  vim.wo[win].foldmethod = "expr"
  vim.wo[win].foldexpr   = "v:lua.text_analyzer_foldexpr(v:lnum)"
  vim.wo[win].foldtext   = "v:lua.text_analyzer_foldtext()"
  vim.wo[win].foldlevel  = 0
  vim.wo[win].foldcolumn = "2"
  vim.wo[win].foldenable = true
end

function M.disable_folds(bufnr)
  if M.is_large_file(bufnr) then return end
  local st  = M.state(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then return end
  local snap = st.saved_folds
  if snap then
    vim.wo[win].foldmethod  = snap.foldmethod
    vim.wo[win].foldexpr    = snap.foldexpr
    vim.wo[win].foldtext    = snap.foldtext
    vim.wo[win].foldlevel   = snap.foldlevel
    vim.wo[win].foldcolumn  = snap.foldcolumn
    vim.wo[win].foldenable  = snap.foldenable
    vim.wo[win].foldminlines = snap.foldminlines
  else
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldexpr   = ""
    vim.wo[win].foldtext   = ""
    vim.wo[win].foldlevel  = 99
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].foldenable = false
  end
  st.saved_folds = nil
end

-- ── Viewport-only Extmarks (small-file mode) ──────────────────────

--- Apply extmarks only within [top, bot] line range.
function M._apply_highlights_range(bufnr, top, bot)
  local st = M.state(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, st.ns_id, top - 1, bot)

  for i = top, bot do
    local visible = st.has_include
        and st.visibility[i]
        or  not (st.excluded and st.excluded[i])

    if visible then
      local best = nil
      for _, f in ipairs(st.filters) do
        if f.enabled and not f.invert and f.match_cache and f.match_cache[i] then
          if not best or f.priority > best.priority then best = f end
        end
      end
      if best then
        vim.api.nvim_buf_set_extmark(bufnr, st.ns_id, i - 1, 0, {
          end_row  = i - 1,
          end_col  = -1,
          hl_group = best:hl_group(),
          priority = best.priority + 100,
          strict   = false,
        })
      end
    end
  end
end

--- Refresh highlights for the current viewport only.
function M.apply_highlights(bufnr)
  if M.is_large_file(bufnr) then return end
  local st  = M.state(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, st.ns_id, 0, -1)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then return end
  local top = vim.fn.line("w0", win)
  local bot = vim.fn.line("w$", win)
  M._apply_highlights_range(bufnr, top, bot)
end

-- ── Large File Results Buffer ─────────────────────────────────────

local COLOR_LABELS = {
  Red    = "RED   ", Yellow = "YELLOW", Green  = "GREEN ",
  Blue   = "BLUE  ", Purple = "PURPLE", Cyan   = "CYAN  ",
  Orange = "ORANGE", Grey   = "GREY  ",
}

--- Run all enabled filters via rg and render results into the scratch buffer.
function M.populate_large_file_results(bufnr)
  local st       = M.state(bufnr)
  local filepath = vim.b[bufnr].ta_large_file
  if not filepath then return end

  M.cancel_search_jobs(bufnr)
  st.match_gen = (st.match_gen or 0) + 1
  local gen    = st.match_gen
  st.results   = {}
  st.line_map  = {}
  st.byte_map  = {}
  st.truncated = false

  local active = {}
  for _, f in ipairs(st.filters) do
    if f.enabled and not f.invert and not f._rg_error then
      table.insert(active, f)
    end
  end

  local size_str    = human_size(vim.fn.getfsize(filepath))
  local fcount      = #active
  local max_results = M.config.max_results or 10000

  -- Show "Searching…" indicator immediately
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "  📂 " .. filepath,
    string.format("  %s  │  %d filter(s)  │  Searching… (cap %d/filter)", size_str, fcount, max_results),
    "",
    "  Escapes:  \\tt toggle  │  \\tr reset  │  \\ta filter panel",
  })
  vim.bo[bufnr].modifiable = false

  if fcount == 0 then
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "  📂 " .. filepath,
      "  " .. size_str .. "  —  Large file mode  (file not loaded into memory)",
      "",
      "  Use :TA <pattern> [color]   to search",
      "  Use \\ta                     to open the filter panel",
      "  Use \\tf                     to add a filter interactively",
      "  Use \\tr                     to reset all filters",
      "  Use \\tt                     to toggle filtering",
      "",
    })
    vim.bo[bufnr].modifiable = false
    get_ui().refresh_panel(bufnr)
    return
  end

  -- Collect rg results from all filters in parallel (capped + byte offsets)
  local all_results = {}
  local pending     = fcount
  local truncated   = false

  for _, filter in ipairs(active) do
    filter._match_gen = (filter._match_gen or 0) + 1
    local fgen = filter._match_gen
    filter.match_cache = {}
    filter._rg_error = nil
    local args = filter_to_rg_args(filter, filepath, {
      byte_offset = true,
      max_count = max_results,
    })
    local f = filter
    local hits = 0
    local jid

    jid = vim.fn.jobstart(args, {
      -- Buffered is safe: --max-count caps output at max_results lines
      stdout_buffered = true,
      on_stdout = function(_, data)
        if f._match_gen ~= fgen or not data then return end
        for _, line in ipairs(data) do
          if line ~= "" and hits < max_results then
            -- rg --byte-offset: lnum:byte:content
            local lnum_s, byte_s, content = line:match("^(%d+):(%d+):(.*)")
            local lnum, byte
            if lnum_s then
              lnum = tonumber(lnum_s)
              byte = tonumber(byte_s)
            else
              local l2, c2 = line:match("^(%d+):(.*)")
              if l2 then
                lnum = tonumber(l2)
                content = c2
              end
            end
            if lnum then
              hits = hits + 1
              f.match_cache[lnum] = true
              table.insert(all_results, {
                line_num = lnum,
                byte = byte,
                filter = f,
                content = content or "",
              })
              if hits >= max_results then
                truncated = true
              end
            end
          end
        end
      end,
      on_stderr = function(_, data)
        if f._match_gen ~= fgen or not data then return end
        for _, line in ipairs(data) do
          if line ~= "" then
            f._rg_error = (f._rg_error and (f._rg_error .. "; ") or "") .. line
          end
        end
      end,
      on_exit = function(_, code)
        _untrack_job(st, jid)
        if f._match_gen ~= fgen then return end
        if hits >= max_results then truncated = true end
        if code and code > 1 then
          f.match_cache = {}
          f._rg_error = f._rg_error or ("rg exit " .. tostring(code))
          vim.schedule(function()
            vim.notify(
              string.format("TextAnalyzer: search failed for '%s' — %s", f.pattern, f._rg_error),
              vim.log.levels.WARN
            )
          end)
        end
        pending = pending - 1
        if pending == 0 and st.match_gen == gen then
          vim.schedule(function()
            M._render_large_results(bufnr, filepath, size_str, all_results, active, truncated)
          end)
        end
      end,
    })
    _track_job(st, jid)
  end
end

-- ── Context slice (load only ±N lines, never the whole file) ──────

local context_winid = nil
local context_bufnr = nil
local CONTEXT_CHUNK = 8192

--- Read [start_ln, end_ln] from filepath via sed/awk (fallback when no byte offset).
local function _read_line_range(filepath, start_ln, end_ln, on_done)
  start_ln = math.max(1, start_ln)
  end_ln = math.max(start_ln, end_ln)

  local cmd
  if vim.fn.executable("sed") == 1 then
    cmd = { "sed", "-n", string.format("%d,%dp", start_ln, end_ln), filepath }
  else
    cmd = {
      "awk",
      "-v", "s=" .. start_ln,
      "-v", "e=" .. end_ln,
      "NR>=s { print } NR>=e { exit }",
      filepath,
    }
  end

  local collected = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= nil then table.insert(collected, line) end
      end
      if #collected > 0 and collected[#collected] == "" then
        table.remove(collected)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 and #collected == 0 then
          on_done(nil, nil, "failed to read lines " .. start_ln .. "-" .. end_ln)
          return
        end
        on_done(collected, start_ln, nil)
      end)
    end,
  })
end

--- Seek-based ±N line read around a known byte offset (O(window), not O(file)).
--- Returns lines, start_ln, err (synchronous; call from vim.schedule if needed).
local function _read_context_at_byte(filepath, byte_offset, center_lnum, context_lines)
  local f, err = io.open(filepath, "rb")
  if not f then return nil, nil, err or "cannot open file" end

  local function find_line_start(pos)
    local search = pos
    while search > 0 do
      local from = math.max(0, search - CONTEXT_CHUNK)
      f:seek("set", from)
      local chunk = f:read(search - from)
      if not chunk or chunk == "" then break end
      local after_nl = chunk:match(".*\n()")
      if after_nl then
        return from + after_nl - 1
      end
      if from == 0 then return 0 end
      search = from
    end
    return 0
  end

  local function find_newline_before(pos)
    local search = pos
    while search > 0 do
      local from = math.max(0, search - CONTEXT_CHUNK)
      f:seek("set", from)
      local chunk = f:read(search - from)
      if not chunk or chunk == "" then break end
      for i = #chunk, 1, -1 do
        if chunk:sub(i, i) == "\n" then
          return from + i - 1 -- file offset of the newline
        end
      end
      if from == 0 then return nil end
      search = from
    end
    return nil
  end

  --- Move back `n` lines from line_start; returns (window_start_byte, lines_moved).
  local function walk_back_lines(line_start, n)
    if n <= 0 or line_start <= 0 then return line_start, 0 end
    local pos = line_start
    local got = 0
    for _ = 1, n do
      local nl = find_newline_before(pos)
      if not nl then
        return 0, got
      end
      -- Start of the line that ends at nl
      pos = find_line_start(nl)
      got = got + 1
    end
    return pos, got
  end

  local function read_n_lines(start_pos, n)
    f:seek("set", start_pos)
    local lines = {}
    local buf = ""
    while #lines < n do
      local chunk = f:read(CONTEXT_CHUNK)
      if not chunk then break end
      buf = buf .. chunk
      while #lines < n do
        local nl = buf:find("\n", 1, true)
        if not nl then break end
        table.insert(lines, buf:sub(1, nl - 1))
        buf = buf:sub(nl + 1)
      end
    end
    if #lines < n and buf ~= "" then
      table.insert(lines, buf)
    end
    return lines
  end

  local ok, result = pcall(function()
    local line_start = find_line_start(byte_offset)
    local window_start, before_got = walk_back_lines(line_start, context_lines)
    local total = before_got + 1 + context_lines
    local lines = read_n_lines(window_start, total)
    local start_ln = math.max(1, center_lnum - before_got)
    return { lines = lines, start_ln = start_ln }
  end)
  f:close()

  if not ok then
    return nil, nil, tostring(result)
  end
  return result.lines, result.start_ln, nil
end

local function _close_context_win()
  if context_winid and vim.api.nvim_win_is_valid(context_winid) then
    pcall(vim.api.nvim_win_close, context_winid, true)
  end
  context_winid = nil
  context_bufnr = nil
end

--- Open a floating window with only ±context_lines around center_lnum.
--- byte_offset (optional): rg match byte for O(1)-ish seek; else sed/awk fallback.
function M.open_context_slice(filepath, center_lnum, context_lines, byte_offset)
  if not filepath or filepath == "" or not center_lnum then return end
  context_lines = context_lines or M.config.context_lines or 25
  context_lines = math.max(1, math.min(context_lines, 500))

  local start_ln = math.max(1, center_lnum - context_lines)
  local end_ln = center_lnum + context_lines

  _close_context_win()

  local buf = vim.api.nvim_create_buf(false, true)
  context_bufnr = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    string.format("  Loading ±%d around line %d…", context_lines, center_lnum),
  })
  vim.bo[buf].modifiable = false

  local width = math.min(120, math.max(60, vim.o.columns - 4))
  local height = math.min(context_lines * 2 + 8, math.max(12, vim.o.lines - 6))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = string.format(" Context ±%d @ %d ", context_lines, center_lnum),
    title_pos = "center",
  })
  context_winid = win
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  pcall(function() vim.wo[win].winfix = "TA-ctx" end)

  vim.b[buf].ta_ctx = {
    filepath = filepath,
    center = center_lnum,
    context_lines = context_lines,
    byte = byte_offset,
  }

  local ns = vim.api.nvim_create_namespace("text-analyzer-context")

  local function render(raw_lines, first_ln)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    first_ln = first_ln or start_ln
    local last_ln = first_ln + math.max(0, #raw_lines - 1)

    local header = {
      string.format("  %s", filepath),
      string.format(
        "  lines %d–%d  │  match @ %d  │  +/− widen/narrow  │  q close",
        first_ln, last_ln, center_lnum
      ),
      "  " .. string.rep("─", math.min(72, width - 4)),
    }
    local display = vim.deepcopy(header)
    local match_buf_row = nil

    for i, content in ipairs(raw_lines) do
      local lnum = first_ln + i - 1
      local marker = (lnum == center_lnum) and "▶" or " "
      table.insert(display, string.format("%s %7d │ %s", marker, lnum, content))
      if lnum == center_lnum then
        match_buf_row = #display - 1
      end
    end

    if #raw_lines == 0 then
      table.insert(display, "  (no lines in range)")
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, display)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if match_buf_row then
      vim.api.nvim_buf_set_extmark(buf, ns, match_buf_row, 0, {
        end_row = match_buf_row,
        end_col = -1,
        hl_group = "TA_Yellow",
        priority = 200,
        strict = false,
      })
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_set_cursor, win, { match_buf_row + 1, 0 })
      end
    end
  end

  local function on_loaded(raw_lines, first_ln, err)
    if err then
      vim.notify("TextAnalyzer: " .. err, vim.log.levels.ERROR)
      _close_context_win()
      return
    end
    render(raw_lines or {}, first_ln)
  end

  if byte_offset then
    vim.schedule(function()
      local lines, first_ln, err = _read_context_at_byte(filepath, byte_offset, center_lnum, context_lines)
      on_loaded(lines, first_ln, err)
    end)
  else
    _read_line_range(filepath, start_ln, end_ln, on_loaded)
  end

  local function reload_with(delta)
    local ctx = vim.b[buf].ta_ctx
    if not ctx then return end
    local next_n = math.max(1, math.min(500, ctx.context_lines + delta))
    M.open_context_slice(ctx.filepath, ctx.center, next_n, ctx.byte)
  end

  vim.keymap.set("n", "q", _close_context_win, { buffer = buf, nowait = true, desc = "Close context" })
  vim.keymap.set("n", "<Esc>", _close_context_win, { buffer = buf, nowait = true, desc = "Close context" })
  vim.keymap.set("n", "+", function() reload_with(25) end, { buffer = buf, nowait = true, desc = "Widen context" })
  vim.keymap.set("n", "=", function() reload_with(25) end, { buffer = buf, nowait = true, desc = "Widen context" })
  vim.keymap.set("n", "-", function() reload_with(-25) end, { buffer = buf, nowait = true, desc = "Narrow context" })
end

function M._render_large_results(bufnr, filepath, size_str, all_results, active_filters, truncated)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local st = M.state(bufnr)
  st.search_jobs = {}
  st.truncated = truncated and true or false

  table.sort(all_results, function(a, b) return a.line_num < b.line_num end)
  st.results = all_results

  local ctx_n = M.config.context_lines or 25
  local max_results = M.config.max_results or 10000

  local header = {
    "  📂 " .. filepath,
    string.format(
      "  %s  │  %d filter(s)  │  %d matches  │  ENTER/o: context ±%d",
      size_str, #active_filters, #all_results, ctx_n
    ),
  }
  if truncated then
    table.insert(header, string.format(
      "  ⚠ truncated at %d matches/filter — narrow your pattern",
      max_results
    ))
  end
  table.insert(header, "  " .. string.rep("─", 72))
  table.insert(header, "")

  local HEADER_COUNT = #header
  local lines = vim.deepcopy(header)
  local line_map = {}
  local byte_map = {}

  for _, r in ipairs(all_results) do
    local label = COLOR_LABELS[r.filter.color] or r.filter.color
    local display = string.format("  [%s]  %7d  │  %s", label, r.line_num, r.content)
    table.insert(lines, display)
    line_map[#lines] = r.line_num
    byte_map[#lines] = r.byte
  end

  if #all_results == 0 then
    table.insert(lines, "  (no matches found)")
    table.insert(lines, "")
    table.insert(lines, "  Filters are still active. Escape hatches:")
    table.insert(lines, "    \\ta  filter panel   \\tr  reset   \\tt  toggle off")
    table.insert(lines, "    :TADel <n>  delete filter by index")
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  st.line_map = line_map
  st.byte_map = byte_map
  vim.b[bufnr].ta_line_map = line_map
  vim.b[bufnr].ta_byte_map = byte_map

  local ns = st.ns_id
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for buf_lnum, _ in pairs(line_map) do
    local r = all_results[buf_lnum - HEADER_COUNT]
    if r then
      vim.api.nvim_buf_set_extmark(bufnr, ns, buf_lnum - 1, 0, {
        end_row  = buf_lnum - 1,
        end_col  = -1,
        hl_group = r.filter:hl_group(),
        priority = 100,
        strict   = false,
      })
    end
  end

  local function open_ctx_at_cursor()
    local cur = vim.fn.line(".")
    local orig_lnum = vim.b[bufnr].ta_line_map and vim.b[bufnr].ta_line_map[cur]
    if not orig_lnum then return end
    local real = vim.b[bufnr].ta_large_file
    if not real then return end
    local byte = vim.b[bufnr].ta_byte_map and vim.b[bufnr].ta_byte_map[cur]
    M.open_context_slice(real, orig_lnum, M.config.context_lines, byte)
  end

  vim.keymap.set("n", "<CR>", open_ctx_at_cursor, { buffer = bufnr, desc = "TextAnalyzer: context slice around match" })
  vim.keymap.set("n", "o", open_ctx_at_cursor, { buffer = bufnr, desc = "TextAnalyzer: context slice around match" })

  vim.keymap.set("n", "q", function()
    _close_context_win()
    vim.cmd("bdelete")
  end, { buffer = bufnr, desc = "TextAnalyzer: close results" })

  local msg = string.format("TextAnalyzer: %d matches across %d filter(s)", #all_results, #active_filters)
  if truncated then
    msg = msg .. " (truncated)"
    vim.notify(msg, vim.log.levels.WARN)
  else
    vim.notify(msg, vim.log.levels.INFO)
  end
  get_ui().refresh_panel(bufnr)
end

--- Open any filepath in large-file analyze mode (never loads full content).
function M.open_large(filepath)
  if not filepath or filepath == "" then
    vim.notify("Usage: TAOpen <filepath>", vim.log.levels.ERROR)
    return
  end
  filepath = vim.fn.fnamemodify(filepath, ":p")
  if vim.fn.filereadable(filepath) == 0 then
    vim.notify("TextAnalyzer: file not found: " .. filepath, vim.log.levels.ERROR)
    return
  end

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  pcall(vim.api.nvim_buf_set_name, buf, "ta://" .. filepath)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = "text-analyzer-results"
  vim.b[buf].ta_large_file = filepath

  M.lighten_buffer(buf)
  M.state(buf)

  local size = vim.fn.getfsize(filepath)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "  📂 " .. filepath,
    "  " .. human_size(size) .. "  —  Large file mode  (file not loaded into memory)",
    "",
    "  Use :TA <pattern> [color]   to search",
    "  Use \\ta                     to open the filter panel",
    "  Use \\tf                     to add a filter interactively",
    "  Use \\tr / \\tt               to reset / toggle filtering",
    "",
  })
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then
      M._auto_load_filters(buf, filepath)
    end
  end)

  vim.notify("TextAnalyzer: opened " .. filepath .. " (large-file mode)", vim.log.levels.INFO)
  return buf
end

-- ── Enable / Disable ──────────────────────────────────────────────

function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if st.enabled then return end
  st.enabled = true

  if M.is_large_file(bufnr) then
    M.populate_large_file_results(bufnr)
  else
    M.recompute_visibility(bufnr)
    M.enable_folds(bufnr)
    M.apply_highlights(bufnr)
  end
  vim.notify("TextAnalyzer: filtering enabled", vim.log.levels.INFO)
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if not st.enabled then return end
  st.enabled = false
  st.empty_match = false

  M.cancel_search_jobs(bufnr)
  st.match_gen = (st.match_gen or 0) + 1

  if M.is_large_file(bufnr) then
    local filepath = vim.b[bufnr].ta_large_file
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "  📂 " .. filepath,
      "  " .. human_size(vim.fn.getfsize(filepath)) .. "  —  Large file mode (filtering disabled)",
      "",
      "  Use :TA <pattern> [color] to re-enable filtering",
      "  Use \\tt to toggle  │  \\tr to reset  │  \\ta for panel",
    })
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(bufnr, st.ns_id, 0, -1)
  else
    M.disable_folds(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, st.ns_id, 0, -1)
  end
  vim.notify("TextAnalyzer: filtering disabled — full file visible", vim.log.levels.INFO)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if st.enabled then M.disable(bufnr) else M.enable(bufnr) end
end

-- ── Internal: run after any filter change ─────────────────────────

local function _refresh(bufnr)
  local st = M.state(bufnr)
  if not st.enabled then
    get_ui().refresh_panel(bufnr)
    return
  end
  if M.is_large_file(bufnr) then
    M.populate_large_file_results(bufnr)
  else
    M.recompute_visibility(bufnr)
    M.apply_highlights(bufnr)
    vim.cmd("redraw!")
    get_ui().refresh_panel(bufnr)
  end
end

-- ── Filter CRUD ────────────────────────────────────────────────────

function M.add_filter(bufnr, filter_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st     = M.state(bufnr)
  local filter = Filter.new(filter_opts)
  table.insert(st.filters, filter)

  -- Auto-enable on first filter
  if not st.enabled then st.enabled = true end

  if M.is_large_file(bufnr) then
    -- Large file: populate_large_file_results runs rg for ALL filters;
    -- no need to call match_filter separately.
    M.populate_large_file_results(bufnr)
  else
    -- Small file: run rg async for just this filter, then refresh.
    M.match_filter(filter, bufnr, function()
      vim.schedule(function()
        M.enable_folds(bufnr)          -- activate folds once cache is ready
        M.recompute_visibility(bufnr)
        M.apply_highlights(bufnr)
        vim.cmd("redraw!")
        get_ui().refresh_panel(bufnr)
      end)
    end)
  end

  return filter
end

function M.remove_filter(bufnr, idx)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if idx < 1 or idx > #st.filters then return end
  table.remove(st.filters, idx)
  _refresh(bufnr)
end

function M.toggle_filter(bufnr, idx)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if idx < 1 or idx > #st.filters then return end
  st.filters[idx].enabled = not st.filters[idx].enabled
  _refresh(bufnr)
end

function M.duplicate_filter(bufnr, idx)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if idx < 1 or idx > #st.filters then return end
  local orig = st.filters[idx]
  local copy = Filter.new({
    name           = orig.name .. " (copy)",
    pattern        = orig.pattern,
    type           = orig.type,
    color          = orig.color,
    enabled        = orig.enabled,
    case_sensitive = orig.case_sensitive,
    invert         = orig.invert,
    priority       = orig.priority,
  })
  table.insert(st.filters, idx + 1, copy)
  M.match_filter(copy, bufnr, function()
    vim.schedule(function() _refresh(bufnr) end)
  end)
end

function M.move_filter_up(bufnr, idx)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if idx <= 1 or idx > #st.filters then return end
  st.filters[idx], st.filters[idx - 1] = st.filters[idx - 1], st.filters[idx]
  _refresh(bufnr)
end

function M.move_filter_down(bufnr, idx)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if idx < 1 or idx >= #st.filters then return end
  st.filters[idx], st.filters[idx + 1] = st.filters[idx + 1], st.filters[idx]
  _refresh(bufnr)
end

function M.reset(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  local was_enabled = st.enabled

  M.cancel_search_jobs(bufnr)
  st.match_gen   = (st.match_gen or 0) + 1
  st.filters     = {}
  st.visibility  = {}
  st.excluded    = {}
  st.has_include = false
  st.empty_match = false
  st.results     = {}
  st.line_map    = {}
  st.byte_map    = {}
  st.truncated   = false

  -- Fully tear down filtering so the buffer is never left "stuck" folded
  if was_enabled then
    M.disable(bufnr)
  elseif not M.is_large_file(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, st.ns_id, 0, -1)
  end
  get_ui().refresh_panel(bufnr)
  vim.notify("TextAnalyzer: all filters cleared — full file visible", vim.log.levels.INFO)
end

--- Toggle invert flag on a filter (exclude ↔ include).
function M.toggle_invert(bufnr, idx)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if idx < 1 or idx > #st.filters then return end
  st.filters[idx].invert = not st.filters[idx].invert
  _refresh(bufnr)
end

--- Update a filter's pattern and re-run matching.
function M.set_filter_pattern(bufnr, idx, new_pattern)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if idx < 1 or idx > #st.filters then return end
  if not new_pattern or new_pattern == "" then return end
  local filter = st.filters[idx]
  filter:set_pattern(new_pattern)
  filter.name = new_pattern
  if M.is_large_file(bufnr) then
    _refresh(bufnr)
  else
    M.match_filter(filter, bufnr, function()
      vim.schedule(function() _refresh(bufnr) end)
    end)
  end
end

--- Cycle filter color forward.
function M.cycle_filter_color(bufnr, idx)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if idx < 1 or idx > #st.filters then return end
  local colors = Filter.COLORS
  local cur = st.filters[idx].color
  local next_i = 1
  for i, c in ipairs(colors) do
    if c == cur then
      next_i = (i % #colors) + 1
      break
    end
  end
  st.filters[idx].color = colors[next_i]
  _refresh(bufnr)
end

-- ── Auto-load Filter Sets ─────────────────────────────────────────

function M._auto_load_filters(bufnr, filename)
  if not filename or filename == "" then return end
  local basename = vim.fn.fnamemodify(filename, ":t")

  for pattern, set_name in pairs(M.config.auto_load) do
    local lua_pat = "^" .. pattern:gsub("%.", "%%."):gsub("%*", ".*"):gsub("?", ".") .. "$"
    if basename:find(lua_pat) then
      local ok, err = pcall(function()
        get_storage().load_into_buffer(bufnr, set_name)
      end)
      if ok then
        vim.notify("TextAnalyzer: auto-loaded '" .. set_name .. "' for " .. basename, vim.log.levels.INFO)
      else
        vim.notify("TextAnalyzer: failed to auto-load '" .. set_name .. "': " .. tostring(err), vim.log.levels.WARN)
      end
      break
    end
  end
end

-- ── Commands ──────────────────────────────────────────────────────

local function complete_ta(arglead, cmdline, _)
  local args = vim.split(cmdline, "%s+")
  if #args == 3 then
    local s = vim.deepcopy(Filter.COLORS)
    table.insert(s, "invert")
    return vim.tbl_filter(function(v) return v:lower():find(arglead:lower(), 1, true) ~= nil end, s)
  elseif #args == 4 and args[3]:lower() ~= "invert" then
    return { "invert" }
  end
  return {}
end

function M._register_commands()
  vim.api.nvim_create_user_command("TA", function(opts)
    local bufnr = vim.api.nvim_get_current_buf()
    if opts.args == "" then
      get_ui().open_panel()
    else
      local args    = opts.fargs
      local pattern = args[1]
      local color   = "Red"
      local invert  = false
      local cl      = {}
      for _, c in ipairs(Filter.COLORS) do cl[c:lower()] = c end
      for i = 2, #args do
        local a = args[i]:lower()
        if cl[a] then color = cl[a]
        elseif a == "invert" or a == "not" or a == "exclude" then invert = true end
      end
      M.add_filter(bufnr, { name = pattern, pattern = pattern, color = color, invert = invert, enabled = true })
    end
  end, { nargs = "*", complete = complete_ta, desc = "Add filter or open panel" })

  vim.api.nvim_create_user_command("TextAnalyzer", function() get_ui().open_panel() end,     { desc = "Open TextAnalyzer panel" })
  vim.api.nvim_create_user_command("TAToggle",     function() M.toggle() end,                { desc = "Toggle filtering" })
  vim.api.nvim_create_user_command("TAReset",      function() M.reset() end,                 { desc = "Reset all filters" })
  vim.api.nvim_create_user_command("TAStats",      function() get_ui().show_stats() end,     { desc = "Show statistics" })
  vim.api.nvim_create_user_command("TAFilterAdd",  function() get_ui().prompt_add_filter() end, { desc = "Add filter (prompt)" })
  vim.api.nvim_create_user_command("TAFilterList", function() get_storage().list_filter_sets() end, { desc = "List filter sets" })
  vim.api.nvim_create_user_command("TAWorkspaceList", function() get_storage().list_workspaces() end, { desc = "List workspaces" })

  vim.api.nvim_create_user_command("TAOpen", function(opts)
    M.open_large(opts.args)
  end, {
    nargs = 1,
    complete = "file",
    desc = "Open any file in TextAnalyzer large-file mode (no full load)",
  })

  vim.api.nvim_create_user_command("TAList", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local st    = M.state(bufnr)
    if #st.filters == 0 then vim.notify("TextAnalyzer: no active filters", vim.log.levels.INFO); return end
    local chunks = { { "TextAnalyzer Filters:\n", "Title" } }
    for i, f in ipairs(st.filters) do
      local icon = f.enabled and "[✓]" or "[ ]"
      local inv  = f.invert and " (Not)" or ""
      table.insert(chunks, { string.format("  %d. %s %-20s ", i, icon, f.name), "Normal" })
      table.insert(chunks, { f.color .. inv .. "\n", f:hl_group() })
    end
    vim.api.nvim_echo(chunks, false, {})
  end, { desc = "List active filters" })

  vim.api.nvim_create_user_command("TADel", function(opts)
    local idx = tonumber(opts.args)
    if not idx then vim.notify("Usage: TADel <index>", vim.log.levels.ERROR); return end
    M.remove_filter(nil, idx)
  end, { nargs = 1, desc = "Delete filter by index" })

  vim.api.nvim_create_user_command("TATog", function(opts)
    local idx = tonumber(opts.args)
    if not idx then vim.notify("Usage: TATog <index>", vim.log.levels.ERROR); return end
    M.toggle_filter(nil, idx)
  end, { nargs = 1, desc = "Toggle filter by index" })

  -- Storage commands
  for cmd, fn in pairs({
    TAFilterSave   = function(a) get_storage().save_filter_set(a) end,
    TAFilterLoad   = function(a) get_storage().load_into_buffer(nil, a) end,
    TAFilterMerge  = function(a) get_storage().merge_into_buffer(nil, a) end,
    TAFilterRemove = function(a) get_storage().delete_filter_set(a) end,
    TAFilterImport = function(a) get_storage().import_filters(a) end,
    TAFilterExport = function(a) get_storage().export_filters(a) end,
    TAWorkspaceSave   = function(a) get_storage().save_workspace(a) end,
    TAWorkspaceLoad   = function(a) get_storage().load_workspace(a) end,
    TAWorkspaceDelete = function(a) get_storage().delete_workspace(a) end,
  }) do
    vim.api.nvim_create_user_command(cmd, function(opts) fn(opts.args) end, { nargs = 1 })
  end

  vim.api.nvim_create_user_command("TAFilterRename", function(opts)
    local args = vim.split(opts.args, "%s+")
    if #args ~= 2 then vim.notify("Usage: TAFilterRename <old> <new>", vim.log.levels.ERROR); return end
    get_storage().rename_filter_set(args[1], args[2])
  end, { nargs = 1, desc = "Rename filter set" })
end

-- ── Keymaps ───────────────────────────────────────────────────────

function M._register_keymaps()
  vim.keymap.set("n", "<leader>ta", function() get_ui().open_panel() end,       { desc = "TextAnalyzer: Open panel" })
  vim.keymap.set("n", "<leader>tf", function() get_ui().prompt_add_filter() end,{ desc = "TextAnalyzer: Add filter" })
  vim.keymap.set("n", "<leader>tt", function() M.toggle() end,                  { desc = "TextAnalyzer: Toggle filtering" })
  vim.keymap.set("n", "<leader>ts", function() get_ui().show_stats() end,       { desc = "TextAnalyzer: Statistics" })
  vim.keymap.set("n", "<leader>tr", function() M.reset() end,                   { desc = "TextAnalyzer: Reset filters" })
  vim.keymap.set("n", "<leader>tl", function() get_ui().show_legend() end,      { desc = "TextAnalyzer: Color legend" })
  vim.keymap.set("n", "<leader>to", function()
    vim.ui.input({ prompt = "TAOpen file: ", completion = "file" }, function(path)
      if path and path ~= "" then M.open_large(path) end
    end)
  end, { desc = "TextAnalyzer: Open file (large-file mode)" })
end

-- ── Autocmds ─────────────────────────────────────────────────────

function M._register_autocmds()
  local group    = vim.api.nvim_create_augroup("text-analyzer", { clear = true })
  local patterns = vim.tbl_map(function(ft) return "*." .. ft end, M.config.enable_filetypes)

  -- BufReadCmd: intercept file open before Neovim reads it.
  -- NOTE: BufReadCmd completely replaces the built-in read, so BufRead/BufReadPost
  -- will NOT fire automatically. We call _auto_load_filters here ourselves.
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group   = group,
    pattern = patterns,
    callback = function(args)
      local filepath = args.file
      local size     = vim.fn.getfsize(filepath)

      M.lighten_buffer(args.buf)

      if size >= 0 and size < M.config.large_file_threshold then
        -- ── Small file: read normally ──────────────────────────────
        vim.cmd("silent keepalt 0read " .. vim.fn.fnameescape(filepath))
        vim.bo[args.buf].modified = false
      else
        -- ── Large file: scratch buffer, never read content ─────────
        vim.bo[args.buf].buftype  = "nofile"
        vim.bo[args.buf].swapfile = false
        vim.bo[args.buf].modified = false
        vim.b[args.buf].ta_large_file = filepath

        vim.bo[args.buf].modifiable = true
        vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, {
          "  📂 " .. filepath,
          "  " .. human_size(size) .. "  —  Large file mode  (file not loaded into memory)",
          "",
          "  Use :TA <pattern> [color]   to search",
          "  Use \\ta                     to open the filter panel",
          "  Use \\tf                     to add a filter interactively",
          "  Use \\tr / \\tt               to reset / toggle filtering",
          "",
        })
        vim.bo[args.buf].modifiable = false
      end

      -- BufRead never fires after BufReadCmd, so trigger auto-load here.
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(args.buf) then
          M._auto_load_filters(args.buf, filepath)
        end
      end)
    end,
  })

  -- BufDelete: cleanup state + cancel jobs
  vim.api.nvim_create_autocmd("BufDelete", {
    group    = group,
    callback = function(args) M.clear_state(args.buf) end,
  })

  -- TextChanged: debounced re-scan (small files only, never for large files)
  local debounce_timer = nil
  vim.api.nvim_create_autocmd("TextChanged", {
    group    = group,
    callback = function(args)
      if not vim.api.nvim_buf_is_valid(args.buf) then return end
      if M.is_large_file(args.buf) then return end
      local st = buf_states[args.buf]
      if not st or not st.enabled or #st.filters == 0 then return end
      if debounce_timer then debounce_timer:stop() end
      debounce_timer = vim.defer_fn(function()
        if not vim.api.nvim_buf_is_valid(args.buf) then return end
        M.match_all_filters(args.buf, function()
          vim.schedule(function()
            M.recompute_visibility(args.buf)
            M.apply_highlights(args.buf)
            vim.cmd("redraw!")
          end)
        end)
      end, 300)
    end,
  })

  -- WinScrolled: refresh only the new viewport (small files)
  vim.api.nvim_create_autocmd("WinScrolled", {
    group    = group,
    callback = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local st    = buf_states[bufnr]
      if not st or not st.enabled or M.is_large_file(bufnr) then return end
      local win = vim.api.nvim_get_current_win()
      local top = vim.fn.line("w0", win)
      local bot = vim.fn.line("w$", win)
      M._apply_highlights_range(bufnr, top, bot)
    end,
  })
end

-- ── LspAttach Guard ──────────────────────────────────────────────

function M._register_lsp_guard()
  vim.api.nvim_create_autocmd("LspAttach", {
    group    = vim.api.nvim_create_augroup("text-analyzer-lsp-guard", { clear = true }),
    callback = function(args)
      if vim.b[args.buf] and vim.b[args.buf].ta_lightened then
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client then pcall(vim.lsp.buf_detach_client, args.buf, client.id) end
      end
    end,
  })
end

-- ── Setup ────────────────────────────────────────────────────────

function M.setup(opts)
  opts     = opts or {}
  M.config = vim.tbl_deep_extend("keep", opts, M.config)

  local config_dir = vim.fn.stdpath("config")
  M.config.filter_dir    = M.config.filter_dir    or (config_dir .. "/textanalyzer/filters")
  M.config.workspace_dir = M.config.workspace_dir or (config_dir .. "/textanalyzer/workspaces")

  vim.fn.mkdir(M.config.filter_dir,    "p")
  vim.fn.mkdir(M.config.workspace_dir, "p")

  Filter.setup_highlights()
  M._register_commands()
  M._register_keymaps()
  M._register_autocmds()
  M._register_lsp_guard()

  vim.notify("TextAnalyzer: loaded", vim.log.levels.DEBUG)
end

return M
