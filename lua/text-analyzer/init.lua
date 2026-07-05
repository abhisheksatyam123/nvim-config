--- text-analyzer/init.lua
--- Entry point: state management, fold hiding, commands, autocmds, buffer lightening.

local Filter = require("text-analyzer.filter")

local M = {}

-- ── State Storage (source of truth) ────────────────────────────────

local buf_states = {}

-- ── Lazy-loaded Modules ────────────────────────────────────────────

local UI, Storage

local function get_ui()
  if not UI then
    UI = require("text-analyzer.ui")
  end
  return UI
end

local function get_storage()
  if not Storage then
    Storage = require("text-analyzer.storage")
  end
  return Storage
end

-- ── Configuration ──────────────────────────────────────────────────

M.config = {
  auto_load = {},                -- filename pattern → filter set name
  filter_dir = nil,              -- set in setup()
  workspace_dir = nil,           -- set in setup()
  enable_filetypes = { "log", "txt" },
  lighten_buffers = true,        -- disable other plugins for analyzed files
}

-- ── Buffer Lightening ──────────────────────────────────────────────
-- When opening .log/.txt files, disable other plugins for speed.

--- Strip all non-essential services from a buffer for performance.
--- Called on BufReadPre for .log/.txt files.
--- @param bufnr number
function M.lighten_buffer(bufnr)
  if not M.config.lighten_buffers then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- 1. Detach any already-attached LSP clients
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    pcall(vim.lsp.buf_detach_client, bufnr, client.id)
  end

  -- 2. Prevent future LSP clients from attaching to this buffer
  --    by setting a buffer-local flag that LspAttach autocmds check.
  vim.b[bufnr].ta_lightened = true

  -- 3. Stop treesitter
  pcall(vim.treesitter.stop, bufnr)

  -- 4. Disable treesitter highlighting for this buffer
  pcall(vim.treesitter.highlighter.disable, bufnr)

  -- 5. Clear matchparen (can be slow on large files)
  pcall(vim.cmd, "NoMatchParen")
end

--- Re-enable selected features if user switches back to normal buffers.
function M.unlighten_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.b[bufnr].ta_lightened = nil
end

-- ── State Accessors ────────────────────────────────────────────────

--- Get or initialize analyzer state for a buffer.
--- @param bufnr number
--- @return table
function M.state(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not buf_states[bufnr] then
    buf_states[bufnr] = {
      filters = {},
      enabled = false,
      visibility = {},
      ns_id = vim.api.nvim_create_namespace("text-analyzer-" .. bufnr),
      saved_foldmethod = nil,
      saved_foldtext = nil,
    }
  end
  return buf_states[bufnr]
end

--- Clear state for a buffer (to prevent memory leaks on close).
--- @param bufnr number
function M.clear_state(bufnr)
  buf_states[bufnr] = nil
end

-- ── Visibility computation ────────────────────────────────────────

--- Recompute visibility from all enabled filters.
--- Stores result in state.visibility (table of line_num → true).
--- @param bufnr number
function M.recompute_visibility(bufnr)
  local st = M.state(bufnr)
  local include = {}
  local exclude = {}
  local has_include = false

  for _, filter in ipairs(st.filters) do
    if filter.enabled then
      local cache = filter.match_cache or {}
      if filter.invert then
        for ln, _ in pairs(cache) do
          exclude[ln] = true
        end
      else
        has_include = true
        for ln, _ in pairs(cache) do
          include[ln] = true
        end
      end
    end
  end

  local visible = {}
  if has_include then
    for ln, _ in pairs(include) do
      if not exclude[ln] then
        visible[ln] = true
      end
    end
  else
    -- Only invert/exclusion filters: show all lines except excluded
    local num_lines = vim.api.nvim_buf_line_count(bufnr)
    for i = 1, num_lines do
      if not exclude[i] then
        visible[i] = true
      end
    end
  end

  st.visibility = visible
end

--- Recompute match cache for a single filter against buffer lines.
--- @param filter table Filter object
--- @param bufnr number
function M.match_filter(filter, bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  filter.match_cache = {}
  for i, line in ipairs(lines) do
    if filter:matches(line) then
      filter.match_cache[i] = true
    end
  end
end

--- Recompute match caches for all filters (full refresh).
--- @param bufnr number
function M.match_all_filters(bufnr)
  local st = M.state(bufnr)
  for _, filter in ipairs(st.filters) do
    M.match_filter(filter, bufnr)
  end
end

-- ── Fold management ────────────────────────────────────────────────

_G.text_analyzer_foldexpr = function(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  local st = buf_states[bufnr]
  if st and st.enabled then
    return st.visibility[lnum] and "0" or "1"
  end
  return "0"
end

_G.text_analyzer_foldtext = function()
  local lines = vim.v.foldend - vim.v.foldstart + 1
  return "╌  " .. lines .. " lines hidden  ╌"
end

--- Enable fold-based filtering for a buffer.
--- @param bufnr number
function M.enable_folds(bufnr)
  local st = M.state(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then return end

  st.saved_foldmethod = vim.wo[winid].foldmethod
  st.saved_foldtext = vim.wo[winid].foldtext

  vim.wo[winid].foldmethod = "expr"
  vim.wo[winid].foldexpr = "v:lua.text_analyzer_foldexpr(v:lnum)"
  vim.wo[winid].foldtext = "v:lua.text_analyzer_foldtext()"
  vim.wo[winid].foldlevel = 0
  vim.wo[winid].foldcolumn = "2"
  vim.wo[winid].foldenable = true
end

--- Disable fold-based filtering and restore original settings.
--- @param bufnr number
function M.disable_folds(bufnr)
  local st = M.state(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then return end

  if st.saved_foldmethod then
    vim.wo[winid].foldmethod = st.saved_foldmethod
  else
    vim.wo[winid].foldmethod = "manual"
  end
  if st.saved_foldtext then
    vim.wo[winid].foldtext = st.saved_foldtext
  else
    vim.wo[winid].foldtext = ""
  end
  vim.wo[winid].foldlevel = 99
  vim.wo[winid].foldcolumn = "0"
end

-- ── Extmark highlights ─────────────────────────────────────────────

--- Apply colored highlights to visible lines based on matching filters.
function M.apply_highlights(bufnr)
  local st = M.state(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, st.ns_id, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    if st.visibility[i] then
      local best_filter = nil
      for _, filter in ipairs(st.filters) do
        if filter.enabled and not filter.invert then
          if filter.match_cache and filter.match_cache[i] then
            if not best_filter or filter.priority > best_filter.priority then
              best_filter = filter
            end
          end
        end
      end
      if best_filter then
        vim.api.nvim_buf_set_extmark(bufnr, st.ns_id, i - 1, 0, {
          end_row = i - 1,
          end_col = -1,
          hl_group = best_filter:hl_group(),
          priority = best_filter.priority + 100,
          strict = false,
        })
      end
    end
  end
end

-- ── Enable / Disable analyzer ─────────────────────────────────────

function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if st.enabled then return end

  st.enabled = true
  M.recompute_visibility(bufnr)
  M.enable_folds(bufnr)
  M.apply_highlights(bufnr)
  vim.notify("TextAnalyzer: filtering enabled", vim.log.levels.INFO)
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if not st.enabled then return end

  st.enabled = false
  M.disable_folds(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, st.ns_id, 0, -1)
  vim.notify("TextAnalyzer: filtering disabled", vim.log.levels.INFO)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if st.enabled then
    M.disable(bufnr)
  else
    M.enable(bufnr)
  end
end

-- ── Filter operations ─────────────────────────────────────────────

function M.add_filter(bufnr, filter_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  local filter = Filter.new(filter_opts)
  table.insert(st.filters, filter)
  M.match_filter(filter, bufnr)
  if st.enabled then
    M.recompute_visibility(bufnr)
    M.apply_highlights(bufnr)
    vim.cmd("redraw!")
  end
  -- Update UI panel if open
  get_ui().refresh_panel(bufnr)
  return filter
end

function M.remove_filter(bufnr, idx)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if idx < 1 or idx > #st.filters then return end
  table.remove(st.filters, idx)
  if st.enabled then
    M.recompute_visibility(bufnr)
    M.apply_highlights(bufnr)
    vim.cmd("redraw!")
  end
  get_ui().refresh_panel(bufnr)
end

function M.toggle_filter(bufnr, idx)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if idx < 1 or idx > #st.filters then return end
  st.filters[idx].enabled = not st.filters[idx].enabled
  if st.enabled then
    M.recompute_visibility(bufnr)
    M.apply_highlights(bufnr)
    vim.cmd("redraw!")
  end
  get_ui().refresh_panel(bufnr)
end

function M.duplicate_filter(bufnr, idx)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if idx < 1 or idx > #st.filters then return end
  local orig = st.filters[idx]
  local copy = Filter.new({
    name = orig.name .. " (copy)",
    pattern = orig.pattern,
    type = orig.type,
    color = orig.color,
    enabled = orig.enabled,
    case_sensitive = orig.case_sensitive,
    invert = orig.invert,
    priority = orig.priority,
  })
  table.insert(st.filters, idx + 1, copy)
  M.match_filter(copy, bufnr)
  if st.enabled then
    M.recompute_visibility(bufnr)
    M.apply_highlights(bufnr)
    vim.cmd("redraw!")
  end
  get_ui().refresh_panel(bufnr)
end

function M.move_filter_up(bufnr, idx)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if idx <= 1 or idx > #st.filters then return end
  st.filters[idx], st.filters[idx - 1] = st.filters[idx - 1], st.filters[idx]
  if st.enabled then
    M.apply_highlights(bufnr)
    vim.cmd("redraw!")
  end
  get_ui().refresh_panel(bufnr)
end

function M.move_filter_down(bufnr, idx)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  if idx < 1 or idx >= #st.filters then return end
  st.filters[idx], st.filters[idx + 1] = st.filters[idx + 1], st.filters[idx]
  if st.enabled then
    M.apply_highlights(bufnr)
    vim.cmd("redraw!")
  end
  get_ui().refresh_panel(bufnr)
end

function M.reset(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = M.state(bufnr)
  st.filters = {}
  st.visibility = {}
  if st.enabled then
    vim.api.nvim_buf_clear_namespace(bufnr, st.ns_id, 0, -1)
    M.recompute_visibility(bufnr)
    vim.cmd("redraw!")
  end
  get_ui().refresh_panel(bufnr)
  vim.notify("TextAnalyzer: all filters cleared", vim.log.levels.INFO)
end

-- ── Auto-load filter sets ──────────────────────────────────────────

function M._auto_load_filters(bufnr, filename)
  if not filename or filename == "" then return end
  local basename = vim.fn.fnamemodify(filename, ":t")

  for pattern, set_name in pairs(M.config.auto_load) do
    local lua_pattern = pattern
    lua_pattern = lua_pattern:gsub("%.", "%%.")
    lua_pattern = lua_pattern:gsub("%*", ".*")
    lua_pattern = lua_pattern:gsub("?", ".")
    lua_pattern = "^" .. lua_pattern .. "$"

    if basename:find(lua_pattern) then
      local ok, err = pcall(function()
        get_storage().load_into_buffer(bufnr, set_name)
      end)
      if ok then
        vim.notify("TextAnalyzer: auto-loaded filter set '" .. set_name .. "' for " .. basename, vim.log.levels.INFO)
        local st = M.state(bufnr)
        if #st.filters > 0 then
          M.match_all_filters(bufnr)
          M.enable(bufnr)
        end
      else
        vim.notify("TextAnalyzer: failed to auto-load '" .. set_name .. "': " .. tostring(err), vim.log.levels.WARN)
      end
      break
    end
  end
end

-- ── Commands ───────────────────────────────────────────────────────

local function complete_ta(arglead, cmdline, cursorpos)
  local args = vim.split(cmdline, "%s+")
  if #args == 3 then
    local suggestions = {}
    for _, c in ipairs(Filter.COLORS) do
      table.insert(suggestions, c)
    end
    table.insert(suggestions, "invert")
    return vim.tbl_filter(function(val)
      return val:lower():find(arglead:lower(), 1, true) ~= nil
    end, suggestions)
  elseif #args == 4 then
    if args[3]:lower() ~= "invert" then
      return { "invert" }
    end
  end
  return {}
end

function M._register_commands()
  -- Unified minimal :TA command
  vim.api.nvim_create_user_command("TA", function(opts)
    if opts.args == "" then
      get_ui().open_panel()
    else
      local args = opts.fargs
      local pattern = args[1]
      local color = "Red"
      local invert = false

      local colors_lower = {}
      for _, c in ipairs(Filter.COLORS) do
        colors_lower[c:lower()] = c
      end

      for i = 2, #args do
        local arg = args[i]:lower()
        if colors_lower[arg] then
          color = colors_lower[arg]
        elseif arg == "invert" or arg == "not" or arg == "exclude" then
          invert = true
        end
      end

      local bufnr = vim.api.nvim_get_current_buf()
      M.add_filter(bufnr, {
        name = pattern,
        pattern = pattern,
        color = color,
        invert = invert,
        enabled = true,
      })

      if not M.state(bufnr).enabled then
        M.enable(bufnr)
      end
    end
  end, {
    nargs = "*",
    complete = complete_ta,
    desc = "Add filter (e.g. :TA ERROR Red invert) or toggle panel if no args",
  })

  vim.api.nvim_create_user_command("TextAnalyzer", function()
    get_ui().open_panel()
  end, { desc = "Open TextAnalyzer panel" })

  vim.api.nvim_create_user_command("TAToggle", function()
    M.toggle()
  end, { desc = "Toggle TextAnalyzer filtering" })

  -- Command-line management commands
  vim.api.nvim_create_user_command("TAList", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local st = M.state(bufnr)
    if #st.filters == 0 then
      vim.notify("TextAnalyzer: no active filters", vim.log.levels.INFO)
      return
    end

    local chunks = { { "TextAnalyzer Filters:\n", "Title" } }
    for i, f in ipairs(st.filters) do
      local icon = f.enabled and "[✓]" or "[ ]"
      local invert_str = f.invert and " (Not)" or ""
      table.insert(chunks, { string.format("  %d. %s %-20s ", i, icon, f.name), "Normal" })
      table.insert(chunks, { f.color .. invert_str .. "\n", f:hl_group() })
    end
    vim.api.nvim_echo(chunks, false, {})
  end, { desc = "List active filters with colors" })

  vim.api.nvim_create_user_command("TADel", function(opts)
    local idx = tonumber(opts.args)
    if not idx then
      vim.notify("Usage: TADel <filter_index>", vim.log.levels.ERROR)
      return
    end
    M.remove_filter(nil, idx)
  end, { nargs = 1, desc = "Delete filter by index" })

  vim.api.nvim_create_user_command("TATog", function(opts)
    local idx = tonumber(opts.args)
    if not idx then
      vim.notify("Usage: TATog <filter_index>", vim.log.levels.ERROR)
      return
    end
    M.toggle_filter(nil, idx)
  end, { nargs = 1, desc = "Toggle filter by index" })

  vim.api.nvim_create_user_command("TAFilterAdd", function()
    get_ui().prompt_add_filter()
  end, { desc = "Add a new filter (prompt)" })

  vim.api.nvim_create_user_command("TAFilterSave", function(opts)
    get_storage().save_filter_set(opts.args)
  end, { nargs = 1, desc = "Save current filters as a named set" })

  vim.api.nvim_create_user_command("TAFilterLoad", function(opts)
    get_storage().load_into_buffer(nil, opts.args)
  end, { nargs = 1, desc = "Load a named filter set" })

  vim.api.nvim_create_user_command("TAFilterMerge", function(opts)
    get_storage().merge_into_buffer(nil, opts.args)
  end, { nargs = 1, desc = "Merge a named filter set into current" })

  vim.api.nvim_create_user_command("TAFilterRename", function(opts)
    local args = vim.split(opts.args, "%s+")
    if #args ~= 2 then
      vim.notify("Usage: TAFilterRename <old> <new>", vim.log.levels.ERROR)
      return
    end
    get_storage().rename_filter_set(args[1], args[2])
  end, { nargs = 1, desc = "Rename a filter set" })

  vim.api.nvim_create_user_command("TAFilterRemove", function(opts)
    get_storage().delete_filter_set(opts.args)
  end, { nargs = 1, desc = "Delete a saved filter set" })

  vim.api.nvim_create_user_command("TAFilterList", function()
    get_storage().list_filter_sets()
  end, { desc = "List saved filter sets" })

  vim.api.nvim_create_user_command("TAFilterImport", function(opts)
    get_storage().import_filters(opts.args)
  end, { nargs = 1, desc = "Import filters from JSON file" })

  vim.api.nvim_create_user_command("TAFilterExport", function(opts)
    get_storage().export_filters(opts.args)
  end, { nargs = 1, desc = "Export filters to JSON file" })

  vim.api.nvim_create_user_command("TAWorkspaceSave", function(opts)
    get_storage().save_workspace(opts.args)
  end, { nargs = 1, desc = "Save workspace" })

  vim.api.nvim_create_user_command("TAWorkspaceLoad", function(opts)
    get_storage().load_workspace(opts.args)
  end, { nargs = 1, desc = "Load workspace" })

  vim.api.nvim_create_user_command("TAWorkspaceList", function()
    get_storage().list_workspaces()
  end, { desc = "List saved workspaces" })

  vim.api.nvim_create_user_command("TAWorkspaceDelete", function(opts)
    get_storage().delete_workspace(opts.args)
  end, { nargs = 1, desc = "Delete workspace" })

  vim.api.nvim_create_user_command("TAStats", function()
    get_ui().show_stats()
  end, { desc = "Show statistics" })

  vim.api.nvim_create_user_command("TAReset", function()
    M.reset()
  end, { desc = "Reset all filters" })
end

-- ── Keymaps ────────────────────────────────────────────────────────

function M._register_keymaps()
  vim.keymap.set("n", "<leader>ta", function() get_ui().open_panel() end, { desc = "TextAnalyzer: Open panel" })
  vim.keymap.set("n", "<leader>tf", function() get_ui().prompt_add_filter() end, { desc = "TextAnalyzer: Add filter" })
  vim.keymap.set("n", "<leader>tt", function() M.toggle() end, { desc = "TextAnalyzer: Toggle filtering" })
  vim.keymap.set("n", "<leader>ts", function() get_ui().show_stats() end, { desc = "TextAnalyzer: Statistics" })
  vim.keymap.set("n", "<leader>tr", function() M.reset() end, { desc = "TextAnalyzer: Reset filters" })
  vim.keymap.set("n", "<leader>tl", function() get_ui().show_legend() end, { desc = "TextAnalyzer: Color legend" })
end

-- ── Autocmds ───────────────────────────────────────────────────────

function M._register_autocmds()
  local group = vim.api.nvim_create_augroup("text-analyzer", { clear = true })

  if M.config.lighten_buffers then
    vim.api.nvim_create_autocmd("BufReadPre", {
      group = group,
      pattern = vim.tbl_map(function(ft) return "*." .. ft end, M.config.enable_filetypes),
      callback = function(args)
        M.lighten_buffer(args.buf)
      end,
    })
  end

  vim.api.nvim_create_autocmd("BufRead", {
    group = group,
    pattern = vim.tbl_map(function(ft) return "*." .. ft end, M.config.enable_filetypes),
    callback = function(args)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(args.buf) then return end
        M.state(args.buf)
        local filename = vim.api.nvim_buf_get_name(args.buf)
        M._auto_load_filters(args.buf, filename)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(args)
      M.clear_state(args.buf)
    end,
  })

  local debounce_timer = nil
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    callback = function(args)
      if not vim.api.nvim_buf_is_valid(args.buf) then return end
      local st = buf_states[args.buf]
      if not st or not st.enabled or #st.filters == 0 then return end

      if debounce_timer then
        debounce_timer:stop()
      end
      debounce_timer = vim.defer_fn(function()
        if not vim.api.nvim_buf_is_valid(args.buf) then return end
        M.match_all_filters(args.buf)
        M.recompute_visibility(args.buf)
        M.apply_highlights(args.buf)
        vim.cmd("redraw!")
      end, 300)
    end,
  })
end

-- ── LspAttach guard ────────────────────────────────────────────────

function M._register_lsp_guard()
  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("text-analyzer-lsp-guard", { clear = true }),
    callback = function(args)
      if vim.b[args.buf] and vim.b[args.buf].ta_lightened then
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client then
          pcall(vim.lsp.buf_detach_client, args.buf, client.id)
        end
      end
    end,
  })
end

-- ── Setup ──────────────────────────────────────────────────────────

function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("keep", opts, M.config)

  local config_dir = vim.fn.stdpath("config")
  M.config.filter_dir = M.config.filter_dir or (config_dir .. "/textanalyzer/filters")
  M.config.workspace_dir = M.config.workspace_dir or (config_dir .. "/textanalyzer/workspaces")

  vim.fn.mkdir(M.config.filter_dir, "p")
  vim.fn.mkdir(M.config.workspace_dir, "p")

  Filter.setup_highlights()

  M._register_commands()
  M._register_keymaps()
  M._register_autocmds()
  M._register_lsp_guard()

  vim.notify("TextAnalyzer: loaded", vim.log.levels.DEBUG)
end

return M
