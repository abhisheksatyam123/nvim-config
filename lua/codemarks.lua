local M = {}

-- SQLite database for search index
M.db_path = vim.fn.expand("~/.codemarks.db")

-- Initialize database
function M.init_db()
  local ok, sqlite = pcall(require, "sqlite")
  if not ok then
    vim.notify("sqlite.lua not available", vim.log.levels.WARN)
    return nil
  end
  
  local db = sqlite.new(M.db_path, { keep_open = true })
  
  -- Create marks table if not exists
  db:eval([[
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
  
  return db
end

-- Find files in the notes vault referencing a code mark name
function M.find_references(name)
  if vim.fn.executable("rg") == 0 then return {} end
  
  local notes_dir = "/home/abhi/notes"
  -- Search for [[name]] or mark:name
  local pattern = string.format([=[\bmark:%s\b|\[\[%s\]\]]=], name, name)
  local cmd = { "rg", "--files-with-matches", vim.fn.shellescape(pattern), vim.fn.shellescape(notes_dir) }
  
  local handle = io.popen(table.concat(cmd, " "))
  if not handle then return {} end
  local result = handle:read("*a")
  handle:close()
  
  local files = {}
  for file in result:gmatch("[^\r\n]+") do
    table.insert(files, file)
  end
  return files
end

-- Rename references of a code mark in notes files
function M.rename_references(old_name, new_name)
  local files = M.find_references(old_name)
  if #files == 0 then return end

  vim.ui.select({ "Yes", "No" }, {
    prompt = string.format("Found %d file(s) referencing '%s'. Update links to '%s'?", #files, old_name, new_name),
  }, function(choice)
    if choice == "Yes" then
      local count = 0
      for _, file in ipairs(files) do
        local f = io.open(file, "r")
        if f then
          local content = f:read("*a")
          f:close()
          -- Replace mark:old_name with mark:new_name
          -- Replace [[old_name]] with [[new_name]]
          local new_content, replacements1 = content:gsub("mark:" .. old_name, "mark:" .. new_name)
          local replacements2
          new_content, replacements2 = new_content:gsub("%[%[" .. old_name .. "%]%]", "[[" .. new_name .. "]]")
          
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

-- Check if a mark exists in database
function M.is_mark_in_db(name)
  local db = M.init_db()
  if not db then return false end
  local res = db:select("marks", { where = { id = name } })
  if res and #res > 0 then
    return true
  end
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

-- Extract mark name under cursor
function M.get_mark_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  -- 1. Pattern: [text](url) where url is mark:<name>
  local start_idx = 1
  while true do
    local s, e, text, url = line:find("%[([^%]]+)%]%(([^%)]+)%)", start_idx)
    if not s then break end
    if col >= s and col <= e then
      local name = url:match("^mark:([%w_%-]+)$")
      if name and M.is_mark_in_db(name) then
        return name
      end
    end
    start_idx = e + 1
  end

  -- 2. Pattern: [[(.-)]] (wikilink style, allows any chars inside brackets)
  start_idx = 1
  while true do
    local s, e, raw_name = line:find("%[%[([^%]]+)%]%]", start_idx)
    if not s then break end
    if col >= s and col <= e then
      local name = raw_name:gsub("^mark:", "")
      if M.is_mark_in_db(name) then
        return name
      end
    end
    start_idx = e + 1
  end

  -- 3. Pattern: mark:([%w_%-]+)
  start_idx = 1
  while true do
    local s, e, name = line:find("mark:([%w_%-]+)", start_idx)
    if not s then break end
    if col >= s and col <= e then
      if M.is_mark_in_db(name) then
        return name
      end
    end
    start_idx = e + 1
  end

  -- 4. Fallback: current word under cursor if it exists in DB
  local word = get_word_at_col(line, col)
  if word and word ~= "" then
    if M.is_mark_in_db(word) then
      return word
    end
  end

  return nil
end

-- Create a code mark for the current cursor position
function M.create_mark()
  vim.ui.input({ prompt = "Enter Code Mark Name: " }, function(name)
    if not name or name == "" then return end
    
    local bufnr = vim.api.nvim_get_current_buf()
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    if filepath == "" then
      vim.notify("Buffer has no file path", vim.log.levels.ERROR)
      return
    end
    
    local clean_name = name:match("^[%w_%-]+$")
    if not clean_name then
      vim.notify("Mark name must be alphanumeric with hyphens/underscores only", vim.log.levels.ERROR)
      return
    end

    local db = M.init_db()
    if not db then
      vim.notify("Database not available", vim.log.levels.ERROR)
      return
    end

    -- Check if mark already exists
    local existing = db:select("marks", { where = { id = clean_name } })
    if existing and #existing > 0 then
      vim.notify("Mark '" .. clean_name .. "' already exists!", vim.log.levels.WARN)
      return
    end

    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local col = vim.api.nvim_win_get_cursor(0)[2] + 1
    local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""

    -- Insert into database
    db:insert("marks", {
      id = clean_name,
      name = clean_name,
      file = filepath,
      line = lnum,
      col = col,
      code = line_text,
    })

    vim.notify("Created code mark: " .. clean_name, vim.log.levels.INFO)
  end)
end

-- Delete a code mark
function M.delete_mark(name)
  local db = M.init_db()
  if not db then
    vim.notify("Database not available", vim.log.levels.ERROR)
    return
  end

  local function do_delete(mark_id)
    db:delete("marks", { id = mark_id })
    vim.notify("Deleted code mark: " .. mark_id, vim.log.levels.INFO)
    
    -- Warn user if the mark is still referenced in note files
    local files = M.find_references(mark_id)
    if #files > 0 then
      local file_list = {}
      for _, f in ipairs(files) do
        table.insert(file_list, vim.fn.fnamemodify(f, ":t"))
      end
      vim.notify(string.format("Note: Deleted mark '%s' is still referenced in: %s", mark_id, table.concat(file_list, ", ")), vim.log.levels.WARN)
    end
  end

  if name and name ~= "" then
    do_delete(name)
    return
  end

  local detected = M.get_mark_under_cursor()
  if detected then
    vim.ui.select({ "Yes", "No" }, {
      prompt = "Delete code mark '" .. detected .. "'?",
    }, function(choice)
      if choice == "Yes" then
        do_delete(detected)
      end
    end)
    return
  end

  local marks = db:select("marks")
  if not marks or #marks == 0 then
    vim.notify("No code marks found to delete", vim.log.levels.WARN)
    return
  end

  local mark_names = {}
  for _, m in ipairs(marks) do
    table.insert(mark_names, m.name)
  end

  vim.ui.select(mark_names, {
    prompt = "Select code mark to delete:",
  }, function(choice)
    if choice then
      do_delete(choice)
    end
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
          local clean_new = new_name:match("^[%w_%-]+$")
          if not clean_new then
            vim.notify("Mark name must be alphanumeric with hyphens/underscores only", vim.log.levels.ERROR)
            return
          end
          local dup = db:select("marks", { where = { id = clean_new } })
          if dup and #dup > 0 then
            vim.notify("Mark '" .. clean_new .. "' already exists!", vim.log.levels.WARN)
            return
          end
          db:update("marks", {
            where = { id = mark_id },
            set = { id = clean_new, name = clean_new }
          })
          vim.notify("Renamed CodeMark '" .. mark_id .. "' to '" .. clean_new .. "'", vim.log.levels.INFO)
          
          -- Ask to rename references in markdown notes
          M.rename_references(mark_id, clean_new)
        end)
      elseif action == "Edit Description" then
        vim.ui.input({ prompt = "Description: ", default = mark.content or "" }, function(new_desc)
          if not new_desc then return end
          db:update("marks", {
            where = { id = mark_id },
            set = { content = new_desc }
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
  for _, m in ipairs(marks) do
    table.insert(mark_names, m.name)
  end

  vim.ui.select(mark_names, {
    prompt = "Select code mark to edit:",
  }, function(choice)
    if choice then
      start_edit(choice)
    end
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
    local col = mark.col or 1

    if vim.fn.filereadable(file) == 0 then
      vim.notify("File not readable: " .. file, vim.log.levels.ERROR)
      return
    end

    local target_buf = vim.fn.bufadd(file)
    vim.fn.bufload(target_buf)
    vim.api.nvim_set_current_buf(target_buf)
    local num_lines = vim.api.nvim_buf_line_count(0)
    if line > num_lines then
      line = num_lines
    end
    vim.api.nvim_win_set_cursor(0, { line, col - 1 })
    vim.cmd("normal! zz")
    vim.notify("Jumped to CodeMark '" .. mark.name .. "' at " .. vim.fn.fnamemodify(file, ":t") .. ":" .. line, vim.log.levels.INFO)
  else
    vim.notify("CodeMark not found: " .. name, vim.log.levels.ERROR)
  end
end

-- Search marks via Telescope
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
  
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local entry_display = require("telescope.pickers.entry_display")
  
  local displayer = entry_display.create({
    separator = " ▏ ",
    items = {
      { width = 20 },
      { width = 45 },
      { remaining = true },
    }
  })
  
  local function make_display(entry)
    local rel_path = vim.fn.fnamemodify(entry.value.file, ":~:.")
    return displayer({
      { entry.value.name, "TelescopeResultsIdentifier" },
      { rel_path .. ":" .. entry.value.line, "TelescopeResultsLineNr" },
      { entry.value.code or "", "TelescopeResultsComment" },
    })
  end
  
  pickers.new({}, {
    prompt_title = "Code Marks",
    finder = finders.new_table({
      results = marks,
      entry_maker = function(entry)
        return {
          value = entry,
          display = make_display,
          ordinal = entry.name .. " " .. entry.file .. " " .. (entry.code or ""),
          filename = entry.file,
          lnum = entry.line,
          col = entry.col,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = conf.file_previewer({}),
  }):find()
end

-- Update line drift on buffer write
function M.update_line_drift(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end
  
  local db = M.init_db()
  if not db then return end
  
  local marks = db:select("marks", { where = { file = filepath } })
  if not marks or #marks == 0 then return end
  
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local num_lines = #lines
  
  for _, mark in ipairs(marks) do
    local orig_line = mark.line
    local orig_code = mark.code
    
    if orig_code and orig_code ~= "" then
      if orig_line <= num_lines and lines[orig_line] == orig_code then
        -- No drift
      else
        local best_line = nil
        local min_dist = math.huge
        
        for idx, line_text in ipairs(lines) do
          if line_text == orig_code then
            local dist = math.abs(idx - orig_line)
            if dist < min_dist then
              min_dist = dist
              best_line = idx
            end
          end
        end
        
        if best_line then
          db:update("marks", {
            where = { id = mark.id },
            set = { line = best_line }
          })
          vim.notify(string.format("CodeMark '%s' drifted from line %d to %d", mark.name, orig_line, best_line), vim.log.levels.INFO)
        end
      end
    end
  end
end

return M
