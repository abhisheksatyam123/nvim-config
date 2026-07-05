--- text-analyzer/ui.lua
--- Floating/split window UI components: filter manager panel, stats, legend.

local Filter = require("text-analyzer.filter")

local UI = {}

local Core
local function get_core()
  if not Core then
    Core = require("text-analyzer")
  end
  return Core
end

-- ── Filter Manager Panel (Vim Split Window) ────────────────────────

local panel_bufnr = nil
local panel_winid = nil

--- Refresh the split panel contents.
--- @param bufnr number Parent buffer number
function UI.refresh_panel(bufnr)
  if not panel_bufnr or not vim.api.nvim_buf_is_valid(panel_bufnr) then return end
  local core = get_core()
  local st = core.state(bufnr)

  local lines = {
    " TA Filters",
    " ──────────",
  }
  local metadata = {}

  if #st.filters == 0 then
    table.insert(lines, "  (No filters)")
  else
    for i, f in ipairs(st.filters) do
      local icon = f.enabled and "✓" or " "
      local invert_str = f.invert and " (Not)" or ""
      local line_text = string.format(" [%s] %d. %s%s (%s)", icon, i, f.name, invert_str, f.color)
      table.insert(lines, line_text)
      metadata[#lines] = i
    end
  end

  table.insert(lines, "")
  table.insert(lines, " ──────────")
  table.insert(lines, " Space : Toggle")
  table.insert(lines, " d     : Delete")
  table.insert(lines, " D     : Duplicate")
  table.insert(lines, " j     : Move Up")
  table.insert(lines, " k     : Move Down")
  table.insert(lines, " q     : Close")

  vim.api.nvim_buf_set_option(panel_bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(panel_bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(panel_bufnr, "modifiable", false)

  vim.b[panel_bufnr]._ta_metadata = metadata
end

--- Open the filter manager panel in a vertical split.
function UI.open_panel()
  local core = get_core()
  -- Close existing panel if open
  if panel_winid and vim.api.nvim_win_is_valid(panel_winid) then
    vim.api.nvim_win_close(panel_winid, true)
    panel_winid = nil
    panel_bufnr = nil
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local st = core.state(bufnr)

  -- Create scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  panel_bufnr = buf
  vim.api.nvim_buf_set_name(buf, "TextAnalyzer Filters")

  -- Open a vertical split on the right side, width 35
  vim.cmd("vertical botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, 35)
  panel_winid = win

  -- Buffer options
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "text-analyzer-panel")

  -- Window options
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  -- Save parent buffer
  vim.b[buf]._ta_parent_buf = bufnr

  -- Update display
  UI.refresh_panel(bufnr)

  -- Keymaps for the panel buffer
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    panel_winid = nil
    panel_bufnr = nil
  end

  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })

  -- Toggle filter
  vim.keymap.set("n", "<Space>", function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local meta = vim.b[buf]._ta_metadata
    local idx = meta[line]
    if idx then
      core.toggle_filter(bufnr, idx)
      UI.refresh_panel(bufnr)
    end
  end, { buffer = buf, nowait = true })

  -- Delete filter
  vim.keymap.set("n", "d", function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local meta = vim.b[buf]._ta_metadata
    local idx = meta[line]
    if idx then
      core.remove_filter(bufnr, idx)
      UI.refresh_panel(bufnr)
    end
  end, { buffer = buf, nowait = true })

  -- Duplicate filter
  vim.keymap.set("n", "D", function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local meta = vim.b[buf]._ta_metadata
    local idx = meta[line]
    if idx then
      core.duplicate_filter(bufnr, idx)
      UI.refresh_panel(bufnr)
    end
  end, { buffer = buf, nowait = true })

  -- Move up
  vim.keymap.set("n", "j", function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local meta = vim.b[buf]._ta_metadata
    local idx = meta[line]
    if idx then
      core.move_filter_up(bufnr, idx)
      UI.refresh_panel(bufnr)
      local new_meta = vim.b[buf]._ta_metadata
      for ln, fi in pairs(new_meta) do
        if fi == idx - 1 then
          pcall(vim.api.nvim_win_set_cursor, win, { ln, 0 })
          break
        end
      end
    end
  end, { buffer = buf, nowait = true })

  -- Move down
  vim.keymap.set("n", "k", function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local meta = vim.b[buf]._ta_metadata
    local idx = meta[line]
    if idx then
      core.move_filter_down(bufnr, idx)
      UI.refresh_panel(bufnr)
      local new_meta = vim.b[buf]._ta_metadata
      for ln, fi in pairs(new_meta) do
        if fi == idx + 1 then
          pcall(vim.api.nvim_win_set_cursor, win, { ln, 0 })
          break
        end
      end
    end
  end, { buffer = buf, nowait = true })
end

-- ── Prompts ────────────────────────────────────────────────────────

function UI.prompt_add_filter()
  vim.ui.input({ prompt = "Filter Pattern: " }, function(pattern)
    if not pattern or pattern == "" then return end
    local bufnr = vim.api.nvim_get_current_buf()
    local core = get_core()
    core.add_filter(bufnr, {
      name = pattern,
      pattern = pattern,
      color = "Red",
      enabled = true,
    })
    if not core.state(bufnr).enabled then
      core.enable(bufnr)
    end
  end)
end

-- ── Stats (Command line echo) ──────────────────────────────────────

function UI.show_stats()
  local core = get_core()
  local bufnr = vim.api.nvim_get_current_buf()
  local st = core.state(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local total = #lines
  local visible = 0
  local filter_counts = {}

  for _, f in ipairs(st.filters) do
    filter_counts[f.name] = 0
  end

  for i, line in ipairs(lines) do
    if st.visibility[i] then
      visible = visible + 1
    end
    for _, f in ipairs(st.filters) do
      if f.match_cache and f.match_cache[i] then
        filter_counts[f.name] = (filter_counts[f.name] or 0) + 1
      end
    end
  end

  local hidden = total - visible

  local chunks = {
    { "TextAnalyzer Statistics:\n", "Title" },
    { string.format("  Total lines:    %d\n", total), "Normal" },
    { string.format("  Visible lines:  %d\n", visible), "Normal" },
    { string.format("  Hidden lines:   %d\n\n", hidden), "Normal" },
  }

  if #st.filters > 0 then
    table.insert(chunks, { "  Filter Match Counts:\n", "Title" })
    for _, f in ipairs(st.filters) do
      local count = filter_counts[f.name] or 0
      local icon = f.enabled and "[✓] " or "[ ] "
      table.insert(chunks, { string.format("    %s%-20s ", icon, f.name), "Normal" })
      table.insert(chunks, { string.format("%d matches\n", count), f:hl_group() })
    end
  end

  vim.api.nvim_echo(chunks, false, {})
end

-- ── Color Legend (Command line echo) ────────────────────────────────

function UI.show_legend()
  local core = get_core()
  local bufnr = vim.api.nvim_get_current_buf()
  local st = core.state(bufnr)

  local chunks = { { "TextAnalyzer Color Legend:\n", "Title" } }

  for _, f in ipairs(st.filters) do
    if f.enabled and not f.invert then
      table.insert(chunks, { string.format("  %-10s ", f.color), f:hl_group() })
      table.insert(chunks, { "— " .. f.name .. "\n", "Normal" })
    end
  end

  if #chunks == 1 then
    table.insert(chunks, { "  No active filters\n", "Normal" })
  end

  vim.api.nvim_echo(chunks, false, {})
end

return UI
