--- text-analyzer/ui.lua
--- Floating/split window UI components: filter manager panel, stats, legend.

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

local function panel_index_at_cursor(win, buf)
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local meta = vim.b[buf]._ta_metadata
  return meta and meta[line]
end

--- Refresh the split panel contents.
--- @param bufnr number Parent buffer number
function UI.refresh_panel(bufnr)
  if not panel_bufnr or not vim.api.nvim_buf_is_valid(panel_bufnr) then return end
  local core = get_core()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = vim.b[panel_bufnr]._ta_parent_buf
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local st = core.state(bufnr)
  local status
  if not st.enabled then
    status = "OFF (full file)"
  elseif st.empty_match then
    status = "0 matches — view unrestricted"
  elseif st.has_include then
    local n = core.visible_count(bufnr) or 0
    status = string.format("ON — %d lines visible", n)
  else
    status = "ON — exclusion mode"
  end

  local lines = {
    " TA Filters",
    " " .. status,
    " ──────────",
  }
  local metadata = {}

  if #st.filters == 0 then
    table.insert(lines, "  (No filters)")
  else
    for i, f in ipairs(st.filters) do
      local icon = f.enabled and "✓" or " "
      local invert_str = f.invert and " !" or ""
      local err = f._rg_error and " ERR" or ""
      local count = core.filter_match_count(f)
      local line_text = string.format(
        " [%s] %d. %s%s (%s)%s  %d",
        icon, i, f.name, invert_str, f.color, err, count
      )
      -- Keep panel readable on narrow splits
      if #line_text > 40 then
        local short = f.name
        if #short > 12 then short = short:sub(1, 11) .. "…" end
        line_text = string.format(
          " [%s] %d. %s%s (%s)%s %d",
          icon, i, short, invert_str, f.color, err, count
        )
      end
      table.insert(lines, line_text)
      metadata[#lines] = i
    end
  end

  table.insert(lines, "")
  table.insert(lines, " ──────────")
  table.insert(lines, " Space : Toggle on/off")
  table.insert(lines, " e     : Edit pattern")
  table.insert(lines, " i     : Invert (exclude)")
  table.insert(lines, " c     : Cycle color")
  table.insert(lines, " d     : Delete")
  table.insert(lines, " D     : Duplicate")
  table.insert(lines, " K     : Move up")
  table.insert(lines, " J     : Move down")
  table.insert(lines, " a     : Add filter")
  table.insert(lines, " t     : Toggle filtering")
  table.insert(lines, " r     : Reset all (escape)")
  table.insert(lines, " q     : Close")

  vim.bo[panel_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(panel_bufnr, 0, -1, false, lines)
  vim.bo[panel_bufnr].modifiable = false

  vim.b[panel_bufnr]._ta_metadata = metadata
  vim.b[panel_bufnr]._ta_parent_buf = bufnr
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
  core.state(bufnr)

  -- Create scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  panel_bufnr = buf
  pcall(vim.api.nvim_buf_set_name, buf, "TextAnalyzer Filters")

  -- Open a vertical split on the right side, width 40
  vim.cmd("vertical botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, 40)
  panel_winid = win

  -- Buffer options
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "text-analyzer-panel"
  vim.bo[buf].modifiable = false

  -- Window options
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].winfix = "TA"

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

  local function parent()
    return vim.b[buf]._ta_parent_buf
  end

  local function with_idx(fn)
    return function()
      local idx = panel_index_at_cursor(win, buf)
      if not idx then return end
      fn(parent(), idx)
      UI.refresh_panel(parent())
    end
  end

  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "Close panel" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, desc = "Close panel" })

  vim.keymap.set("n", "<Space>", with_idx(function(pb, idx)
    core.toggle_filter(pb, idx)
  end), { buffer = buf, nowait = true, desc = "Toggle filter" })

  vim.keymap.set("n", "d", with_idx(function(pb, idx)
    core.remove_filter(pb, idx)
  end), { buffer = buf, nowait = true, desc = "Delete filter" })

  vim.keymap.set("n", "D", with_idx(function(pb, idx)
    core.duplicate_filter(pb, idx)
  end), { buffer = buf, nowait = true, desc = "Duplicate filter" })

  -- Vim-natural: K = up, J = down (shifted so j/k still move the cursor)
  vim.keymap.set("n", "K", function()
    local idx = panel_index_at_cursor(win, buf)
    if not idx then return end
    local pb = parent()
    core.move_filter_up(pb, idx)
    UI.refresh_panel(pb)
    local new_meta = vim.b[buf]._ta_metadata
    for ln, fi in pairs(new_meta or {}) do
      if fi == idx - 1 then
        pcall(vim.api.nvim_win_set_cursor, win, { ln, 0 })
        break
      end
    end
  end, { buffer = buf, nowait = true, desc = "Move filter up" })

  vim.keymap.set("n", "J", function()
    local idx = panel_index_at_cursor(win, buf)
    if not idx then return end
    local pb = parent()
    core.move_filter_down(pb, idx)
    UI.refresh_panel(pb)
    local new_meta = vim.b[buf]._ta_metadata
    for ln, fi in pairs(new_meta or {}) do
      if fi == idx + 1 then
        pcall(vim.api.nvim_win_set_cursor, win, { ln, 0 })
        break
      end
    end
  end, { buffer = buf, nowait = true, desc = "Move filter down" })

  vim.keymap.set("n", "i", with_idx(function(pb, idx)
    core.toggle_invert(pb, idx)
  end), { buffer = buf, nowait = true, desc = "Invert filter" })

  vim.keymap.set("n", "c", with_idx(function(pb, idx)
    core.cycle_filter_color(pb, idx)
  end), { buffer = buf, nowait = true, desc = "Cycle color" })

  vim.keymap.set("n", "e", function()
    local idx = panel_index_at_cursor(win, buf)
    if not idx then return end
    local pb = parent()
    local st = core.state(pb)
    local f = st.filters[idx]
    if not f then return end
    vim.ui.input({ prompt = "Edit pattern: ", default = f.pattern }, function(new_pat)
      if not new_pat or new_pat == "" then return end
      core.set_filter_pattern(pb, idx, new_pat)
      UI.refresh_panel(pb)
    end)
  end, { buffer = buf, nowait = true, desc = "Edit filter pattern" })

  vim.keymap.set("n", "a", function()
    local pb = parent()
    -- Prompt while keeping parent as the filter target
    vim.ui.input({ prompt = "Filter Pattern: " }, function(pattern)
      if not pattern or pattern == "" then return end
      core.add_filter(pb, {
        name = pattern,
        pattern = pattern,
        color = "Red",
        enabled = true,
      })
      UI.refresh_panel(pb)
    end)
  end, { buffer = buf, nowait = true, desc = "Add filter" })

  -- Escape hatches: always available from the panel
  vim.keymap.set("n", "t", function()
    core.toggle(parent())
    UI.refresh_panel(parent())
  end, { buffer = buf, nowait = true, desc = "Toggle filtering (escape)" })

  vim.keymap.set("n", "r", function()
    core.reset(parent())
    UI.refresh_panel(parent())
  end, { buffer = buf, nowait = true, desc = "Reset all filters (escape)" })
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

  if st.empty_match then
    visible = total
  elseif st.has_include then
    for i, _ in ipairs(lines) do
      if st.visibility[i] then
        visible = visible + 1
      end
    end
  else
    for i, _ in ipairs(lines) do
      if not (st.excluded and st.excluded[i]) then
        visible = visible + 1
      end
    end
  end

  for i, _ in ipairs(lines) do
    for _, f in ipairs(st.filters) do
      if f.match_cache and f.match_cache[i] then
        filter_counts[f.name] = (filter_counts[f.name] or 0) + 1
      end
    end
  end

  local hidden = total - visible

  local chunks = {
    { "TextAnalyzer Statistics:\n", "Title" },
    { string.format("  Enabled:       %s\n", st.enabled and "yes" or "no"), "Normal" },
    { string.format("  Total lines:   %d\n", total), "Normal" },
    { string.format("  Visible lines: %d\n", visible), "Normal" },
    { string.format("  Hidden lines:  %d\n", hidden), "Normal" },
  }

  if st.empty_match then
    table.insert(chunks, { "  Note: 0 matches — view left unrestricted\n\n", "WarningMsg" })
  else
    table.insert(chunks, { "\n", "Normal" })
  end

  if #st.filters > 0 then
    table.insert(chunks, { "  Filter Match Counts:\n", "Title" })
    for _, f in ipairs(st.filters) do
      local count = filter_counts[f.name] or 0
      local icon = f.enabled and "[✓] " or "[ ] "
      local err = f._rg_error and " [ERR]" or ""
      table.insert(chunks, { string.format("    %s%-20s ", icon, f.name), "Normal" })
      table.insert(chunks, { string.format("%d matches%s\n", count, err), f:hl_group() })
    end
  end

  table.insert(chunks, { "\n  Escapes: \\tt toggle │ \\tr reset │ \\ta panel\n", "Comment" })

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
