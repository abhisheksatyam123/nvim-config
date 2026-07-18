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
      saved_foldmethod = nil,
      saved_foldtext   = nil,
      -- large-file results
      results          = {},   -- array of { line_num, filter, content }
      line_map         = {},   -- buf_line (1-indexed) → original file line_num
      search_jobs      = {},   -- active jobstart ids (for cancellation)
    }
  end
  return buf_states[bufnr]
end

function M.clear_state(bufnr)
  local st = buf_states[bufnr]
  if st then
    for _, jid in ipairs(st.search_jobs or {}) do
      pcall(vim.fn.jobstop, jid)
    end
  end
  buf_states[bufnr] = nil
end

-- ── rg-based Async Matching ────────────────────────────────────────

local function filter_to_rg_args(filter, filepath)
  local args = { "rg", "--line-number", "--no-heading", "--color=never" }
  if not filter.case_sensitive then table.insert(args, "--ignore-case") end
  if filter.type == "literal"  then table.insert(args, "--fixed-strings") end
  table.insert(args, "--")
  table.insert(args, filter.pattern)
  table.insert(args, filepath)
  return args
end

--- Match a single filter against the file using rg (async).
--- on_done() is called when rg exits. filter.match_cache is populated.
function M.match_filter(filter, bufnr, on_done)
  local filepath = M.get_filepath(bufnr)
  if filepath == "" then
    filter.match_cache = {}
    if on_done then on_done() end
    return
  end

  -- Graceful fallback: if rg is not installed, use Lua loop (small files only)
  if vim.fn.executable("rg") == 0 then
    filter.match_cache = {}
    if not M.is_large_file(bufnr) then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for i, line in ipairs(lines) do
        if filter:matches(line) then filter.match_cache[i] = true end
      end
    end
    if on_done then on_done() end
    return
  end

  filter.match_cache = {}
  local args = filter_to_rg_args(filter, filepath)

  vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then
          local lnum = line:match("^(%d+):")
          if lnum then filter.match_cache[tonumber(lnum)] = true end
        end
      end
    end,
    on_exit = function()
      -- rg exits 0 (matches) or 1 (no matches) — both are fine
      if on_done then on_done() end
    end,
  })
end

--- Match all filters in parallel. Calls on_done() when every rg job finishes.
function M.match_all_filters(bufnr, on_done)
  local st = M.state(bufnr)
  if #st.filters == 0 then
    if on_done then on_done() end
    return
  end
  local pending = #st.filters
  local function check()
    pending = pending - 1
    if pending == 0 and on_done then on_done() end
  end
  for _, filter in ipairs(st.filters) do
    M.match_filter(filter, bufnr, check)
  end
end

-- ── Visibility (small-file mode) ──────────────────────────────────

function M.recompute_visibility(bufnr)
  if M.is_large_file(bufnr) then return end
  local st = M.state(bufnr)
  local include, exclude, has_include = {}, {}, false

  for _, filter in ipairs(st.filters) do
    if filter.enabled then
      local cache = filter.match_cache or {}
      if filter.invert then
        for ln in pairs(cache) do exclude[ln] = true end
      else
        has_include = true
        for ln in pairs(cache) do include[ln] = true end
      end
    end
  end

  if has_include then
    local visible = {}
    for ln in pairs(include) do
      if not exclude[ln] then visible[ln] = true end
    end
    st.visibility  = visible
    st.excluded    = {}
    st.has_include = true
  else
    -- Exclusion-only: store only the excluded lines (tiny table vs 10M-entry table)
    st.visibility  = {}
    st.excluded    = exclude
    st.has_include = false
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
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then return end
  st.saved_foldmethod = vim.wo[win].foldmethod
  st.saved_foldtext   = vim.wo[win].foldtext
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
  vim.wo[win].foldmethod = st.saved_foldmethod or "manual"
  vim.wo[win].foldtext   = st.saved_foldtext   or ""
  vim.wo[win].foldlevel  = 99
  vim.wo[win].foldcolumn = "0"
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

  -- Cancel any in-flight jobs
  for _, jid in ipairs(st.search_jobs) do pcall(vim.fn.jobstop, jid) end
  st.search_jobs = {}
  st.results     = {}
  st.line_map    = {}

  local active = {}
  for _, f in ipairs(st.filters) do
    if f.enabled and not f.invert then table.insert(active, f) end
  end

  local size_str  = human_size(vim.fn.getfsize(filepath))
  local fcount    = #active

  -- Show "Searching…" indicator immediately
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "  📂 " .. filepath,
    string.format("  %s  │  %d filter(s)  │  Searching…", size_str, fcount),
    "",
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
      "",
    })
    vim.bo[bufnr].modifiable = false
    return
  end

  -- Collect rg results from all filters in parallel
  local all_results = {}
  local pending     = fcount

  for _, filter in ipairs(active) do
    filter.match_cache = {}
    local args = filter_to_rg_args(filter, filepath)
    local f    = filter  -- capture

    local jid = vim.fn.jobstart(args, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        if not data then return end
        for _, line in ipairs(data) do
          if line ~= "" then
            local lnum_s, content = line:match("^(%d+):(.*)")
            if lnum_s then
              local lnum = tonumber(lnum_s)
              f.match_cache[lnum] = true
              table.insert(all_results, { line_num = lnum, filter = f, content = content })
            end
          end
        end
      end,
      on_exit = function()
        pending = pending - 1
        if pending == 0 then
          vim.schedule(function()
            M._render_large_results(bufnr, filepath, size_str, all_results, active)
          end)
        end
      end,
    })
    table.insert(st.search_jobs, jid)
  end
end

function M._render_large_results(bufnr, filepath, size_str, all_results, active_filters)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local st = M.state(bufnr)
  st.search_jobs = {}

  -- Sort by line number
  table.sort(all_results, function(a, b) return a.line_num < b.line_num end)
  st.results = all_results

  -- Build display lines
  local header = {
    "  📂 " .. filepath,
    string.format(
      "  %s  │  %d filter(s)  │  %d matches  │  ENTER: jump to file",
      size_str, #active_filters, #all_results
    ),
    "  " .. string.rep("─", 72),
    "",
  }
  local HEADER_COUNT = #header
  local lines   = vim.deepcopy(header)
  local line_map = {}

  for _, r in ipairs(all_results) do
    local label   = COLOR_LABELS[r.filter.color] or r.filter.color
    local display = string.format("  [%s]  %7d  │  %s", label, r.line_num, r.content)
    table.insert(lines, display)
    line_map[#lines] = r.line_num
  end

  if #all_results == 0 then
    table.insert(lines, "  (no matches found)")
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  st.line_map = line_map
  vim.b[bufnr].ta_line_map = line_map

  -- Apply color extmarks to result lines
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

  -- Enter: jump to the matched line in the real file (read-only view)
  vim.keymap.set("n", "<CR>", function()
    local cur = vim.fn.line(".")
    local orig_lnum = vim.b[bufnr].ta_line_map and vim.b[bufnr].ta_line_map[cur]
    if not orig_lnum then return end
    local real = vim.b[bufnr].ta_large_file
    vim.cmd("view " .. vim.fn.fnameescape(real))
    local max = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(orig_lnum, max), 0 })
    vim.cmd("normal! zz")
  end, { buffer = bufnr, desc = "TextAnalyzer: jump to line in file" })

  -- q: close results buffer
  vim.keymap.set("n", "q", function()
    vim.cmd("bdelete")
  end, { buffer = bufnr, desc = "TextAnalyzer: close results" })

  vim.notify(string.format("TextAnalyzer: %d matches across %d filter(s)", #all_results, #active_filters), vim.log.levels.INFO)
  get_ui().refresh_panel(bufnr)
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

  if M.is_large_file(bufnr) then
    -- Stop any running jobs and restore welcome screen
    for _, jid in ipairs(st.search_jobs) do pcall(vim.fn.jobstop, jid) end
    st.search_jobs = {}
    local filepath = vim.b[bufnr].ta_large_file
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "  📂 " .. filepath,
      "  " .. human_size(vim.fn.getfsize(filepath)) .. "  —  Large file mode (filtering disabled)",
      "",
      "  Use :TA <pattern> [color] to re-enable filtering",
    })
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(bufnr, st.ns_id, 0, -1)
  else
    M.disable_folds(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, st.ns_id, 0, -1)
  end
  vim.notify("TextAnalyzer: filtering disabled", vim.log.levels.INFO)
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

  -- Run rg async; refresh UI when done
  M.match_filter(filter, bufnr, function()
    vim.schedule(function() _refresh(bufnr) end)
  end)

  -- For large files, kick off the full result rebuild (it will cancel/restart)
  if M.is_large_file(bufnr) then
    M.populate_large_file_results(bufnr)
  else
    M.enable_folds(bufnr)
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
  -- Cancel in-flight jobs
  for _, jid in ipairs(st.search_jobs) do pcall(vim.fn.jobstop, jid) end
  st.filters     = {}
  st.visibility  = {}
  st.excluded    = {}
  st.has_include = false
  st.results     = {}
  st.line_map    = {}
  st.search_jobs = {}

  if st.enabled then
    if M.is_large_file(bufnr) then
      M.populate_large_file_results(bufnr)
    else
      vim.api.nvim_buf_clear_namespace(bufnr, st.ns_id, 0, -1)
      M.recompute_visibility(bufnr)
      vim.cmd("redraw!")
    end
  end
  get_ui().refresh_panel(bufnr)
  vim.notify("TextAnalyzer: all filters cleared", vim.log.levels.INFO)
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
end

-- ── Autocmds ─────────────────────────────────────────────────────

function M._register_autocmds()
  local group    = vim.api.nvim_create_augroup("text-analyzer", { clear = true })
  local patterns = vim.tbl_map(function(ft) return "*." .. ft end, M.config.enable_filetypes)

  -- BufReadCmd: intercept file open before Neovim reads it
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group   = group,
    pattern = patterns,
    callback = function(args)
      local filepath = args.file
      local size     = vim.fn.getfsize(filepath)

      M.lighten_buffer(args.buf)

      if size >= 0 and size < M.config.large_file_threshold then
        -- ── Small file: read normally ──────────────────────────────
        -- 0read inserts at the very start (no blank-line issue)
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
          "",
        })
        vim.bo[args.buf].modifiable = false
      end
    end,
  })

  -- BufRead: trigger auto-load filter sets
  vim.api.nvim_create_autocmd("BufRead", {
    group   = group,
    pattern = patterns,
    callback = function(args)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(args.buf) then return end
        M._auto_load_filters(args.buf, vim.api.nvim_buf_get_name(args.buf))
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
