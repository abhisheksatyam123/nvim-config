local M = {}

-- SQLite database for search index
M.db_path = vim.fn.expand("~/.codemarks.db")
local _db = nil

-- Extmark namespace for gutter signs + virtual text
M.ns = vim.api.nvim_create_namespace("codemarks")

-- Define highlight groups once (idempotent)
local function setup_highlights()
  vim.api.nvim_set_hl(0, "CodeMarkSign",     { fg = "#f5a97f", bold = true })
  vim.api.nvim_set_hl(0, "CodeMarkVirtText", { fg = "#6e738d", italic = true })
end
setup_highlights()
-- Re-apply after colorscheme changes
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = setup_highlights,
  desc = "Re-apply CodeMark highlight groups after colorscheme change",
})

-- Initialize database
function M.init_db()
  if _db then return _db end

  local ok, sqlite = pcall(require, "sqlite")
  if not ok then
    vim.notify("sqlite.lua not available", vim.log.levels.WARN)
    return nil
  end

  local ok_new, db = pcall(sqlite.new, M.db_path, { keep_open = true })
  if not ok_new then
    vim.notify("sqlite.lua: " .. tostring(db), vim.log.levels.ERROR)
    return nil
  end
  _db = db

  -- Create marks table if not exists
  _db:eval([[
    CREATE TABLE IF NOT EXISTS marks (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      file TEXT NOT NULL,
      line INTEGER NOT NULL,
      col INTEGER NOT NULL,
      code TEXT,
      content TEXT,
      created_at TEXT DEFAULT (datetime('now'))
    )
  ]])

  return _db
end

-- ─────────────────────────────────────────────────────────────
--  Gutter signs + virtual text
-- ─────────────────────────────────────────────────────────────

-- Render extmarks for all marks in a given buffer
function M.refresh_signs(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  -- Clear previous extmarks for this buffer
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

  local db = M.init_db()
  if not db then return end

  local marks = db:select("marks", { where = { file = filepath } })
  if not marks or #marks == 0 then return end

  local num_lines = vim.api.nvim_buf_line_count(bufnr)
  for _, mark in ipairs(marks) do
    local line0 = mark.line - 1 -- convert to 0-indexed
    if line0 >= 0 and line0 < num_lines then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, line0, 0, {
        sign_text     = "◆",
        sign_hl_group = "CodeMarkSign",
        virt_text     = { { "  ← " .. mark.name, "CodeMarkVirtText" } },
        virt_text_pos = "eol",
        priority      = 10,
      })
    end
  end
end

-- Refresh signs in all currently loaded buffers (e.g. after a delete)
local function refresh_all_bufs()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.refresh_signs(bufnr)
    end
  end
end

-- ─────────────────────────────────────────────────────────────
--  Notes-vault reference helpers
-- ─────────────────────────────────────────────────────────────

-- Find files in the notes vault referencing a code mark name
function M.find_references(name)
  if vim.fn.executable("rg") == 0 then return {} end

  local notes_dir = "/home/abhi/notes"
  -- Pass args as a list → no shell, no double-escaping
  local pattern = string.format([[\\bmark:%s\\b|\\[\\[%s\\]\\]]], name, name)
  local result = vim.fn.system({ "rg", "--files-with-matches", pattern, notes_dir })
  if vim.v.shell_error ~= 0 and result == "" then return {} end

  local files = {}
  for file in result:gmatch("[^\r\n]+") do
    table.insert(files, file)
  end
  return files
end

-- Rename references of a code mark in notes files
local function escape_pattern(str)
  return str:gsub("([^%w])", "%%%1")
end

function M.rename_references(old_name, new_name)
  local files = M.find_references(old_name)
  if #files == 0 then return end

  vim.ui.select({ "Yes", "No" }, {
    prompt = string.format("Found %d file(s) referencing '%s'. Update links to '%s'?", #files, old_name, new_name),
  }, function(choice)
    if choice == "Yes" then
      local count = 0
      local escaped_old = escape_pattern(old_name)
      for _, file in ipairs(files) do
        local f = io.open(file, "r")
        if f then
          local content = f:read("*a")
          f:close()
          local new_content, replacements1 = content:gsub("mark:" .. escaped_old, "mark:" .. new_name)
          local replacements2
          new_content, replacements2 = new_content:gsub("%[%[" .. escaped_old .. "%]%]", "[[" .. new_name .. "]]")
          if replacements1 > 0 or replacements2 > 0 then
            local wf = io.open(file, "w")
            if wf then
              wf:write(new_content)
              wf:close()
              count = count + 1
            end
          end
        end
      end
      vim.notify(string.format("Updated references in %d file(s)", count), vim.log.levels.INFO)
    else
      vim.notify("References were not updated. Note files may still contain links to the old mark name.", vim.log.levels.WARN)
    end
  end)
end

-- ─────────────────────────────────────────────────────────────
--  Core DB helpers
-- ─────────────────────────────────────────────────────────────

-- Check if a mark exists in database
function M.is_mark_in_db(name)
  local db = M.init_db()
  if not db then return false end
  local res = db:select("marks", { where = { id = name } })
  if res and #res > 0 then return true end
  res = db:select("marks", { where = { name = name } })
  return res and #res > 0
end

-- Helper to extract contiguous alphanumeric/hyphen/underscore word at column
local function get_word_at_col(line, col)
  local start_idx = 1
  while true do
    local s, e = line:find("[%w_%-]+", start_idx)
    if not s then break end
    if col >= s and col <= e then
      return line:sub(s, e)
    end
    start_idx = e + 1
  end
  return nil
end

-- Extract mark name under cursor (supports mark:name, [[name]], [text](mark:name), plain word)
function M.get_mark_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  -- 1. [text](mark:<name>)
  local start_idx = 1
  while true do
    local s, e, _, url = line:find("%[([^%]]+)%]%(([^%)]+)%)", start_idx)
    if not s then break end
    if col >= s and col <= e then
      local name = url:match("^mark:(.+)$")
      if name then
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if M.is_mark_in_db(name) then return name end
      end
    end
    start_idx = e + 1
  end

  -- 2. [[name]] wikilink
  start_idx = 1
  while true do
    local s, e, raw_name = line:find("%[%[([^%]]+)%]%]", start_idx)
    if not s then break end
    if col >= s and col <= e then
      local name = raw_name:gsub("^mark:", "")
      name = name:gsub("^%s+", ""):gsub("%s+$", "")
      local pipe_idx = name:find("|")
      if pipe_idx then name = name:sub(1, pipe_idx - 1) end
      name = name:gsub("^%s+", ""):gsub("%s+$", "")
      if M.is_mark_in_db(name) then return name end
    end
    start_idx = e + 1
  end

  -- 3. mark:<name>
  start_idx = 1
  while true do
    local s, e, raw_name = line:find("mark:([%w_%-%s%.%/%:]+)", start_idx)
    if not s then break end
    if col >= s and col <= e then
      local words = {}
      for word in raw_name:gmatch("%S+") do table.insert(words, word) end
      local candidate = ""
      local best_match = nil
      for i, w in ipairs(words) do
        candidate = (i == 1) and w or (candidate .. " " .. w)
        local clean = candidate:gsub("[%.,;%?!]$", "")
        if M.is_mark_in_db(candidate) then best_match = candidate
        elseif M.is_mark_in_db(clean) then best_match = clean end
      end
      if best_match then return best_match end
    end
    start_idx = e + 1
  end

  -- 4. Fallback: plain word under cursor
  local word = get_word_at_col(line, col)
  if word and word ~= "" and M.is_mark_in_db(word) then return word end

  return nil
end

-- ─────────────────────────────────────────────────────────────
--  CRUD operations
-- ─────────────────────────────────────────────────────────────

-- Create a code mark for the current cursor position
function M.create_mark()
  vim.ui.input({ prompt = "Enter Code Mark Name: " }, function(name)
    if not name or name == "" then return end

    local bufnr   = vim.api.nvim_get_current_buf()
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    if filepath == "" then
      vim.notify("Buffer has no file path", vim.log.levels.ERROR)
      return
    end

    local clean_name = name:match("^[^%[%]%(%)|]+$")
    if clean_name then clean_name = clean_name:gsub("^%s+", ""):gsub("%s+$", "") end
    if not clean_name or clean_name == "" then
      vim.notify("Mark name cannot contain brackets, parentheses, or pipe characters", vim.log.levels.ERROR)
      return
    end

    local db = M.init_db()
    if not db then
      vim.notify("Database not available", vim.log.levels.ERROR)
      return
    end

    local existing = db:select("marks", { where = { id = clean_name } })
    if existing and #existing > 0 then
      vim.notify("Mark '" .. clean_name .. "' already exists!", vim.log.levels.WARN)
      return
    end

    local lnum      = vim.api.nvim_win_get_cursor(0)[1]
    local col       = vim.api.nvim_win_get_cursor(0)[2] + 1
    local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""

    db:insert("marks", {
      id   = clean_name,
      name = clean_name,
      file = filepath,
      line = lnum,
      col  = col,
      code = line_text,
    })

    -- Immediately show the sign in the current buffer
    M.refresh_signs(bufnr)
    vim.notify("Created code mark: " .. clean_name, vim.log.levels.INFO)
  end)
end

-- Internal delete (no UI prompt) — used by picker and delete_mark
local function _do_delete(db, mark_id)
  db:delete("marks", { id = mark_id })
  refresh_all_bufs()
  vim.notify("Deleted code mark: " .. mark_id, vim.log.levels.INFO)
  -- Warn if still referenced in notes
  local files = M.find_references(mark_id)
  if #files > 0 then
    local names = {}
    for _, f in ipairs(files) do table.insert(names, vim.fn.fnamemodify(f, ":t")) end
    vim.notify(string.format("Note: '%s' is still referenced in: %s", mark_id, table.concat(names, ", ")), vim.log.levels.WARN)
  end
end

-- Delete a code mark (detects under cursor, otherwise shows picker)
function M.delete_mark(name)
  local db = M.init_db()
  if not db then
    vim.notify("Database not available", vim.log.levels.ERROR)
    return
  end

  if name and name ~= "" then
    _do_delete(db, name)
    return
  end

  local detected = M.get_mark_under_cursor()
  if detected then
    vim.ui.select({ "Yes", "No" }, {
      prompt = "Delete code mark '" .. detected .. "'?",
    }, function(choice)
      if choice == "Yes" then _do_delete(db, detected) end
    end)
    return
  end

  local marks = db:select("marks")
  if not marks or #marks == 0 then
    vim.notify("No code marks found to delete", vim.log.levels.WARN)
    return
  end

  local mark_names = {}
  for _, m in ipairs(marks) do table.insert(mark_names, m.name) end

  vim.ui.select(mark_names, {
    prompt = "Select code mark to delete:",
  }, function(choice)
    if choice then _do_delete(db, choice) end
  end)
end

-- Edit a code mark (rename or description)
function M.edit_mark()
  local db = M.init_db()
  if not db then
    vim.notify("Database not available", vim.log.levels.ERROR)
    return
  end

  local detected = M.get_mark_under_cursor()
  local function start_edit(mark_id)
    local res = db:select("marks", { where = { id = mark_id } })
    if not res or #res == 0 then
      vim.notify("Mark not found: " .. mark_id, vim.log.levels.ERROR)
      return
    end
    local mark = res[1]

    vim.ui.select({ "Rename", "Edit Description" }, {
      prompt = "Edit CodeMark '" .. mark_id .. "':",
    }, function(action)
      if action == "Rename" then
        vim.ui.input({ prompt = "New name for " .. mark_id .. ": ", default = mark_id }, function(new_name)
          if not new_name or new_name == "" or new_name == mark_id then return end
          local clean_new = new_name:match("^[^%[%]%(%)|]+$")
          if clean_new then clean_new = clean_new:gsub("^%s+", ""):gsub("%s+$", "") end
          if not clean_new or clean_new == "" then
            vim.notify("Mark name cannot contain brackets, parentheses, or pipe characters", vim.log.levels.ERROR)
            return
          end
          local dup = db:select("marks", { where = { id = clean_new } })
          if dup and #dup > 0 then
            vim.notify("Mark '" .. clean_new .. "' already exists!", vim.log.levels.WARN)
            return
          end
          db:update("marks", {
            where = { id = mark_id },
            set   = { id = clean_new, name = clean_new },
          })
          -- Refresh signs so new name shows in virtual text
          refresh_all_bufs()
          vim.notify("Renamed CodeMark '" .. mark_id .. "' to '" .. clean_new .. "'", vim.log.levels.INFO)
          M.rename_references(mark_id, clean_new)
        end)
      elseif action == "Edit Description" then
        vim.ui.input({ prompt = "Description: ", default = mark.content or "" }, function(new_desc)
          if not new_desc then return end
          db:update("marks", {
            where = { id = mark_id },
            set   = { content = new_desc },
          })
          vim.notify("Updated description for CodeMark '" .. mark_id .. "'", vim.log.levels.INFO)
        end)
      end
    end)
  end

  if detected then
    start_edit(detected)
    return
  end

  local marks = db:select("marks")
  if not marks or #marks == 0 then
    vim.notify("No code marks found to edit", vim.log.levels.WARN)
    return
  end

  local mark_names = {}
  for _, m in ipairs(marks) do table.insert(mark_names, m.name) end

  vim.ui.select(mark_names, {
    prompt = "Select code mark to edit:",
  }, function(choice)
    if choice then start_edit(choice) end
  end)
end

-- Jump to a code mark by name
function M.goto_mark(name)
  local db = M.init_db()
  if not db then return end

  local res = db:select("marks", { where = { id = name } })
  if not res or #res == 0 then
    res = db:select("marks", { where = { name = name } })
  end

  if res and #res > 0 then
    local mark = res[1]
    local file = mark.file
    local line = mark.line
    local col  = mark.col or 1

    if vim.fn.filereadable(file) == 0 then
      vim.notify("File not readable: " .. file, vim.log.levels.ERROR)
      return
    end

    -- edit fires BufReadPost → LSP/treesitter attach properly
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    local num_lines = vim.api.nvim_buf_line_count(0)
    line = math.min(line, num_lines)
    vim.api.nvim_win_set_cursor(0, { line, col - 1 })
    vim.cmd("normal! zz")
    vim.notify("Jumped to CodeMark '" .. mark.name .. "' at " .. vim.fn.fnamemodify(file, ":t") .. ":" .. line, vim.log.levels.INFO)
  else
    vim.notify("CodeMark not found: " .. name, vim.log.levels.ERROR)
  end
end

-- ─────────────────────────────────────────────────────────────
--  \fm — fzf-lua picker with jump + CTRL-D delete
-- ─────────────────────────────────────────────────────────────

function M.search_marks()
  local db = M.init_db()
  if not db then
    vim.notify("Database not available", vim.log.levels.ERROR)
    return
  end

  local marks = db:select("marks")
  if not marks or #marks == 0 then
    vim.notify("No code marks found", vim.log.levels.WARN)
    return
  end

  local fzf = require("fzf-lua")

  -- Build display list and a lookup table keyed by display string
  local results   = {}
  local info_map  = {} -- display_str → { name, file, line, col }
  for _, entry in ipairs(marks) do
    local rel_path = vim.fn.fnamemodify(entry.file, ":~:.")
    local display  = string.format(
      "%-30s │ %s:%d  %s",
      entry.name,
      rel_path,
      entry.line,
      entry.code or ""
    )
    table.insert(results, display)
    info_map[display] = {
      name = entry.name,
      file = entry.file,
      line = entry.line,
      col  = entry.col or 1,
    }
  end

  local function jump_to(info)
    vim.cmd("edit " .. vim.fn.fnameescape(info.file))
    local num_lines = vim.api.nvim_buf_line_count(0)
    local line = math.min(info.line, num_lines)
    vim.api.nvim_win_set_cursor(0, { line, info.col - 1 })
    vim.cmd("normal! zz")
  end

  fzf.fzf_exec(results, {
    prompt = "CodeMarks❯ ",
    fzf_opts = {
      ["--multi"]  = true,
      ["--header"] = "ENTER: jump  │  CTRL-D: delete",
    },
    actions = {
      -- Default: jump to the selected mark
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        local info = info_map[selected[1]]
        if info then jump_to(info) end
      end,

      -- CTRL-D: delete selected marks (supports multi-select), then reopen
      ["ctrl-d"] = function(selected)
        if not selected or #selected == 0 then return end
        local deleted = {}
        for _, sel in ipairs(selected) do
          local info = info_map[sel]
          if info then
            _do_delete(db, info.name)
            table.insert(deleted, info.name)
          end
        end
        if #deleted > 0 then
          -- Brief delay so the notify shows before picker reopens
          vim.defer_fn(function()
            M.search_marks()
          end, 50)
        end
      end,
    },
  })
end

-- ─────────────────────────────────────────────────────────────
--  Line-drift tracking on save
-- ─────────────────────────────────────────────────────────────

function M.update_line_drift(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  local db = M.init_db()
  if not db then return end

  local marks = db:select("marks", { where = { file = filepath } })
  if not marks or #marks == 0 then return end

  local lines    = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local num_lines = #lines
  local drifted  = false

  for _, mark in ipairs(marks) do
    local orig_line = mark.line
    local orig_code = mark.code
    if orig_code and orig_code ~= "" then
      if not (orig_line <= num_lines and lines[orig_line] == orig_code) then
        local best_line, min_dist = nil, math.huge
        for idx, line_text in ipairs(lines) do
          if line_text == orig_code then
            local dist = math.abs(idx - orig_line)
            if dist < min_dist then min_dist = dist; best_line = idx end
          end
        end
        if best_line then
          db:update("marks", {
            where = { id = mark.id },
            set   = { line = best_line },
          })
          vim.notify(string.format("CodeMark '%s' drifted: line %d → %d", mark.name, orig_line, best_line), vim.log.levels.INFO)
          drifted = true
        end
      end
    end
  end

  -- Redraw signs if any line numbers changed
  if drifted then M.refresh_signs(bufnr) end
end

return M
