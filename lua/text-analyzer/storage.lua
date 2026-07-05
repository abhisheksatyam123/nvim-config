--- text-analyzer/storage.lua
--- Persistence: filter sets, workspaces, import/export.

local Filter = require("text-analyzer.filter")

local Storage = {}

local Core
local function get_core()
  if not Core then
    Core = require("text-analyzer")
  end
  return Core
end

-- ── Helpers ────────────────────────────────────────────────────────

--- Get the filter sets directory.
function Storage._filter_dir()
  return get_core().config.filter_dir
end

--- Get the workspaces directory.
function Storage._workspace_dir()
  return get_core().config.workspace_dir
end

--- Sanitize a name to a safe filename.
local function safe_name(name)
  return name:gsub("[^%w_%-]", "_")
end

--- List JSON files in a directory (without extension).
local function list_names(dir)
  if vim.fn.isdirectory(dir) == 0 then return {} end
  local entries = vim.fn.readdir(dir)
  local names = {}
  for _, entry in ipairs(entries) do
    local name = entry:match("^(.+)%.json$")
    if name then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

-- ── Filter Sets ────────────────────────────────────────────────────

--- Save current buffer's filters as a named filter set.
--- @param name string
function Storage.save_filter_set(name)
  if not name or name == "" then
    vim.notify("Usage: TAFilterSave <name>", vim.log.levels.ERROR)
    return
  end

  local core = get_core()
  local bufnr = vim.api.nvim_get_current_buf()
  local st = core.state(bufnr)

  local data = {
    name = name,
    created_at = os.date("%Y-%m-%dT%H:%M:%S"),
    filters = {},
  }

  for _, f in ipairs(st.filters) do
    table.insert(data.filters, f:to_table())
  end

  local filepath = Storage._filter_dir() .. "/" .. safe_name(name) .. ".json"
  local ok, err = pcall(function()
    local file = io.open(filepath, "w")
    if not file then error("Cannot open " .. filepath) end
    file:write(vim.fn.json_encode(data))
    file:close()
  end)

  if ok then
    vim.notify("TextAnalyzer: filter set '" .. name .. "' saved (" .. #st.filters .. " filters)", vim.log.levels.INFO)
  else
    vim.notify("TextAnalyzer: failed to save filter set: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Load a named filter set into the current buffer.
--- Replaces all existing filters.
--- @param bufnr number|nil
--- @param name string
function Storage.load_into_buffer(bufnr, name)
  local core = get_core()
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local filepath = Storage._filter_dir() .. "/" .. safe_name(name) .. ".json"
  if vim.fn.filereadable(filepath) == 0 then
    vim.notify("TextAnalyzer: filter set '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  local ok, data = pcall(function()
    local file = io.open(filepath, "r")
    if not file then error("Cannot open " .. filepath) end
    local content = file:read("*a")
    file:close()
    return vim.fn.json_decode(content)
  end)

  if not ok then
    vim.notify("TextAnalyzer: failed to load filter set: " .. tostring(data), vim.log.levels.ERROR)
    return
  end

  -- Replace filters
  local st = core.state(bufnr)
  st.filters = {}
  for _, ft in ipairs(data.filters or {}) do
    table.insert(st.filters, Filter.from_table(ft))
  end

  -- Recompute
  core.match_all_filters(bufnr)
  if st.enabled then
    core.recompute_visibility(bufnr)
    core.apply_highlights(bufnr)
    vim.cmd("redraw!")
  end

  vim.notify("TextAnalyzer: loaded filter set '" .. name .. "' (" .. #st.filters .. " filters)", vim.log.levels.INFO)
end

--- Merge a named filter set into the current buffer's filters.
--- @param bufnr number|nil
--- @param name string
function Storage.merge_into_buffer(bufnr, name)
  local core = get_core()
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local filepath = Storage._filter_dir() .. "/" .. safe_name(name) .. ".json"
  if vim.fn.filereadable(filepath) == 0 then
    vim.notify("TextAnalyzer: filter set '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  local ok, data = pcall(function()
    local file = io.open(filepath, "r")
    if not file then error("Cannot open " .. filepath) end
    local content = file:read("*a")
    file:close()
    return vim.fn.json_decode(content)
  end)

  if not ok then
    vim.notify("TextAnalyzer: failed to load filter set: " .. tostring(data), vim.log.levels.ERROR)
    return
  end

  local st = core.state(bufnr)
  local start_count = #st.filters

  for _, ft in ipairs(data.filters or {}) do
    table.insert(st.filters, Filter.from_table(ft))
  end

  core.match_all_filters(bufnr)
  if st.enabled then
    core.recompute_visibility(bufnr)
    core.apply_highlights(bufnr)
    vim.cmd("redraw!")
  end

  local added = #st.filters - start_count
  vim.notify("TextAnalyzer: merged " .. added .. " filters from '" .. name .. "'", vim.log.levels.INFO)
end

--- Rename a saved filter set.
function Storage.rename_filter_set(old_name, new_name)
  local old_path = Storage._filter_dir() .. "/" .. safe_name(old_name) .. ".json"
  local new_path = Storage._filter_dir() .. "/" .. safe_name(new_name) .. ".json"

  if vim.fn.filereadable(old_path) == 0 then
    vim.notify("TextAnalyzer: filter set '" .. old_name .. "' not found", vim.log.levels.ERROR)
    return
  end

  if vim.fn.filereadable(new_path) == 1 then
    vim.notify("TextAnalyzer: filter set '" .. new_name .. "' already exists", vim.log.levels.ERROR)
    return
  end

  local ok, err = os.rename(old_path, new_path)
  if ok then
    vim.notify("TextAnalyzer: filter set renamed '" .. old_name .. "' → '" .. new_name .. "'", vim.log.levels.INFO)
  else
    vim.notify("TextAnalyzer: failed to rename: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Delete a saved filter set.
function Storage.delete_filter_set(name)
  local filepath = Storage._filter_dir() .. "/" .. safe_name(name) .. ".json"
  if vim.fn.filereadable(filepath) == 0 then
    vim.notify("TextAnalyzer: filter set '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  vim.ui.select({ "Yes", "No" }, { prompt = "Delete filter set '" .. name .. "'?" }, function(choice)
    if choice == "Yes" then
      os.remove(filepath)
      vim.notify("TextAnalyzer: filter set '" .. name .. "' deleted", vim.log.levels.INFO)
    end
  end)
end

--- List all saved filter sets.
function Storage.list_filter_sets()
  local names = list_names(Storage._filter_dir())
  if #names == 0 then
    vim.notify("TextAnalyzer: no saved filter sets", vim.log.levels.INFO)
    return
  end

  local chunks = { { "Saved Filter Sets:\n", "Title" } }
  for _, name in ipairs(names) do
    table.insert(chunks, { "  • " .. name .. "\n", "Normal" })
  end
  vim.api.nvim_echo(chunks, false, {})
end

-- ── Import / Export ────────────────────────────────────────────────

--- Export current filters to a JSON file.
--- @param filepath string
function Storage.export_filters(filepath)
  if not filepath or filepath == "" then
    vim.notify("Usage: TAFilterExport <filepath>", vim.log.levels.ERROR)
    return
  end

  local core = get_core()
  local bufnr = vim.api.nvim_get_current_buf()
  local st = core.state(bufnr)

  local data = {
    exported_at = os.date("%Y-%m-%dT%H:%M:%S"),
    filters = {},
  }

  for _, f in ipairs(st.filters) do
    table.insert(data.filters, f:to_table())
  end

  local ok, err = pcall(function()
    local file = io.open(filepath, "w")
    if not file then error("Cannot open " .. filepath) end
    file:write(vim.fn.json_encode(data))
    file:close()
  end)

  if ok then
    vim.notify("TextAnalyzer: exported " .. #st.filters .. " filters to " .. filepath, vim.log.levels.INFO)
  else
    vim.notify("TextAnalyzer: export failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Import filters from a JSON file (adds to current filters).
--- @param filepath string
function Storage.import_filters(filepath)
  if not filepath or filepath == "" then
    vim.notify("Usage: TAFilterImport <filepath>", vim.log.levels.ERROR)
    return
  end

  if vim.fn.filereadable(filepath) == 0 then
    vim.notify("TextAnalyzer: file not found: " .. filepath, vim.log.levels.ERROR)
    return
  end

  local ok, data = pcall(function()
    local file = io.open(filepath, "r")
    if not file then error("Cannot open " .. filepath) end
    local content = file:read("*a")
    file:close()
    return vim.fn.json_decode(content)
  end)

  if not ok then
    vim.notify("TextAnalyzer: failed to parse file: " .. tostring(data), vim.log.levels.ERROR)
    return
  end

  local core = get_core()
  local bufnr = vim.api.nvim_get_current_buf()
  local st = core.state(bufnr)
  local imported = 0

  for _, ft in ipairs(data.filters or {}) do
    table.insert(st.filters, Filter.from_table(ft))
    imported = imported + 1
  end

  core.match_all_filters(bufnr)
  if st.enabled then
    core.recompute_visibility(bufnr)
    core.apply_highlights(bufnr)
    vim.cmd("redraw!")
  end

  vim.notify("TextAnalyzer: imported " .. imported .. " filters from " .. filepath, vim.log.levels.INFO)
end

-- ── Workspaces ─────────────────────────────────────────────────────

--- Save full workspace (filters + state + scroll position).
--- @param name string
function Storage.save_workspace(name)
  if not name or name == "" then
    vim.notify("Usage: TAWorkspaceSave <name>", vim.log.levels.ERROR)
    return
  end

  local core = get_core()
  local bufnr = vim.api.nvim_get_current_buf()
  local st = core.state(bufnr)
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  local scroll = {}
  if winid ~= -1 then
    scroll = { row = vim.fn.line("w0", winid), col = vim.fn.virtcol(".") }
  end

  local data = {
    name = name,
    created_at = os.date("%Y-%m-%dT%H:%M:%S"),
    updated_at = os.date("%Y-%m-%dT%H:%M:%S"),
    file = filename,
    scroll = scroll,
    enabled = st.enabled,
    context_mode = st.context_mode or "all",
    filters = {},
  }

  for _, f in ipairs(st.filters) do
    table.insert(data.filters, f:to_table())
  end

  local filepath = Storage._workspace_dir() .. "/" .. safe_name(name) .. ".json"
  local ok, err = pcall(function()
    local file = io.open(filepath, "w")
    if not file then error("Cannot open " .. filepath) end
    file:write(vim.fn.json_encode(data))
    file:close()
  end)

  if ok then
    vim.notify("TextAnalyzer: workspace '" .. name .. "' saved", vim.log.levels.INFO)
  else
    vim.notify("TextAnalyzer: failed to save workspace: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Load a saved workspace.
--- @param name string
function Storage.load_workspace(name)
  local filepath = Storage._workspace_dir() .. "/" .. safe_name(name) .. ".json"
  if vim.fn.filereadable(filepath) == 0 then
    vim.notify("TextAnalyzer: workspace '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  local ok, data = pcall(function()
    local file = io.open(filepath, "r")
    if not file then error("Cannot open " .. filepath) end
    local content = file:read("*a")
    file:close()
    return vim.fn.json_decode(content)
  end)

  if not ok then
    vim.notify("TextAnalyzer: failed to load workspace: " .. tostring(data), vim.log.levels.ERROR)
    return
  end

  -- Open the file if specified
  local bufnr
  if data.file and data.file ~= "" and vim.fn.filereadable(data.file) == 1 then
    bufnr = vim.fn.bufadd(data.file)
    vim.fn.bufload(bufnr)
    vim.api.nvim_set_current_buf(bufnr)
  else
    bufnr = vim.api.nvim_get_current_buf()
  end

  local core = get_core()
  -- Restore filters
  local st = core.state(bufnr)
  st.filters = {}
  for _, ft in ipairs(data.filters or {}) do
    table.insert(st.filters, Filter.from_table(ft))
  end

  st.context_mode = data.context_mode or "all"
  st.enabled = data.enabled ~= false

  -- Recompute
  core.match_all_filters(bufnr)
  if st.enabled then
    core.recompute_visibility(bufnr)
    core.enable_folds(bufnr)
    core.apply_highlights(bufnr)

    -- Restore scroll position
    if data.scroll and data.scroll.row then
      local winid = vim.fn.bufwinid(bufnr)
      if winid ~= -1 then
        pcall(vim.api.nvim_win_set_cursor, winid, { data.scroll.row, data.scroll.col or 0 })
        vim.cmd("normal! zz")
      end
    end
  end

  vim.notify("TextAnalyzer: workspace '" .. name .. "' loaded (" .. #st.filters .. " filters)", vim.log.levels.INFO)
end

--- List saved workspaces.
function Storage.list_workspaces()
  local names = list_names(Storage._workspace_dir())
  if #names == 0 then
    vim.notify("TextAnalyzer: no saved workspaces", vim.log.levels.INFO)
    return
  end

  local chunks = { { "Saved Workspaces:\n", "Title" } }
  for _, name in ipairs(names) do
    table.insert(chunks, { "  • " .. name .. "\n", "Normal" })
  end
  vim.api.nvim_echo(chunks, false, {})
end

--- Delete a workspace.
function Storage.delete_workspace(name)
  local filepath = Storage._workspace_dir() .. "/" .. safe_name(name) .. ".json"
  if vim.fn.filereadable(filepath) == 0 then
    vim.notify("TextAnalyzer: workspace '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  vim.ui.select({ "Yes", "No" }, { prompt = "Delete workspace '" .. name .. "'?" }, function(choice)
    if choice == "Yes" then
      os.remove(filepath)
      vim.notify("TextAnalyzer: workspace '" .. name .. "' deleted", vim.log.levels.INFO)
    end
  end)
end

return Storage
