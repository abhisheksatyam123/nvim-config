--- typist/tracker.lua
--- Insert-session WPM (neotypist-style) + word-boundary capture for learning.

local Tracker = {}

local Spell = require("typist.spell")
local Store = require("typist.store")

local ns = vim.api.nvim_create_namespace("Typist")
local uv = vim.uv or vim.loop

local config = {}
local enabled = true

local session = {
  timer = nil,
  start_time = 0,
  start_words = 0,
  session_id = nil,
  last_wpm = 0,
  words_typed = 0,
  recent_wrong = nil, -- last spell-bad word this insert session
  last_token = nil,   -- avoid double-processing same token
}

local WORD_PATTERN = "[%a']+"

local function ignored_ft(ft)
  for _, f in ipairs(config.ignore_filetypes or {}) do
    if f == ft then return true end
  end
  return false
end

local function clear_virt()
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

local function render_wpm(wpm)
  if not config.show_wpm then return end
  local buf = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local text = (config.virt_text or function(w)
    return ("WPM: %.0f"):format(w)
  end)(wpm)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_text = { { text, "Comment" } },
    virt_text_pos = config.virt_text_pos or "right_align",
  })
end

local function tick()
  if not enabled then return end
  local now = uv.now()
  local dt = (now - session.start_time) / 1000
  if dt <= 0 then return end

  local words = vim.fn.wordcount().words
  local typed = math.max(0, words - session.start_words)
  session.words_typed = typed
  local wpm = typed / (dt / 60)
  session.last_wpm = wpm
  render_wpm(wpm)
end

--- Extract the word immediately left of the cursor (or just-finished word).
local function word_left_of_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  if col == 0 then
    -- just wrapped or at start; try end of previous finished token on this line
    return nil
  end

  -- Character just typed is often a delimiter at col; look at text before cursor
  local before = line:sub(1, col)
  -- If last char is a word char, word isn't finished yet
  local last = before:sub(-1)
  if last:match("[%a']") then
    return nil
  end

  -- Strip trailing delimiter and capture last word
  local stripped = before:gsub("%s+$", ""):gsub("[%p%d]+$", "")
  local word = stripped:match(WORD_PATTERN .. "$")
  return word
end

--- Force-capture current incomplete word (InsertLeave).
local function word_under_or_left()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local before = line:sub(1, col)
  local word = before:match(WORD_PATTERN .. "$")
  if word then return word end
  -- try token just before a delimiter
  local stripped = before:gsub("[%p%s%d]+$", "")
  return stripped:match(WORD_PATTERN .. "$")
end

local function accept_token(word)
  if not word then return end
  local min_len = config.min_word_len or 3
  if #word < min_len then return end
  if word:match("^%d+$") then return end

  local key = word:lower()
  if session.last_token == key then return end
  session.last_token = key

  local ft = vim.bo.filetype
  local good = Spell.process_word(word, config, ft, session.recent_wrong)
  if good == false then
    session.recent_wrong = word
  elseif good == true then
    session.recent_wrong = nil
  end
end

function Tracker.on_text_changed()
  if not enabled then return end
  if ignored_ft(vim.bo.filetype) then return end
  local word = word_left_of_cursor()
  if word then
    accept_token(word)
  end
end

function Tracker.start()
  if not enabled then return end
  if ignored_ft(vim.bo.filetype) then return end
  if session.timer then return end

  session.timer = uv.new_timer()
  session.start_time = uv.now()
  session.start_words = vim.fn.wordcount().words
  session.words_typed = 0
  session.last_wpm = 0
  session.recent_wrong = nil
  session.last_token = nil
  session.session_id = Store.start_session()

  local interval = config.update_time or 300
  session.timer:start(0, interval, vim.schedule_wrap(tick))
end

function Tracker.stop()
  -- Capture trailing word before leaving insert
  if enabled and not ignored_ft(vim.bo.filetype) then
    local word = word_under_or_left()
    if word then accept_token(word) end
  end

  if session.timer then
    session.timer:stop()
    session.timer:close()
    session.timer = nil
  end

  if session.session_id then
    Store.end_session(session.session_id, session.last_wpm, session.words_typed)
    session.session_id = nil
  end

  clear_virt()
end

function Tracker.setup(opts)
  config = opts or config
end

function Tracker.set_enabled(val)
  enabled = val and true or false
  if not enabled then
    Tracker.stop()
  end
end

function Tracker.is_enabled()
  return enabled
end

function Tracker.last_wpm()
  return session.last_wpm
end

return Tracker
