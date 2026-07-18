--- typist/init.lua
--- Personal typing / spell-learn plugin (neotypist-inspired WPM + SQLite word bank).

local M = {}

local Store = require("typist.store")
local Tracker = require("typist.tracker")
local CmpSource = require("typist.cmp_source")

M.config = {
  db_path = nil, -- default: stdpath("data")/typist.db
  show_wpm = true,
  update_time = 300,
  min_word_len = 3,
  ignore_filetypes = { "TelescopePrompt", "fzf", "oil", "text-analyzer-panel", "text-analyzer-results" },
  learn_without_spell = true, -- still learn words in code filetypes
  enable_spell_learn = { "markdown", "text", "gitcommit", "org", "mail" },
  cmp = { enable = true, max_items = 20 },
  virt_text_pos = "right_align",
  virt_text = function(wpm)
    return ("WPM: %.0f"):format(wpm)
  end,
}

local function register_commands()
  vim.api.nvim_create_user_command("TypistStats", function()
    M.stats()
  end, { desc = "Typist: show stats" })

  vim.api.nvim_create_user_command("TypistAdd", function(opts)
    local word = opts.args
    if not word or word == "" then
      vim.notify("Usage: TypistAdd <word>", vim.log.levels.ERROR)
      return
    end
    Store.upsert_word(word, "manual", 5)
    vim.notify("Typist: added '" .. word:lower() .. "'", vim.log.levels.INFO)
  end, { nargs = 1, desc = "Typist: add word to dictionary" })

  vim.api.nvim_create_user_command("TypistIgnore", function(opts)
    local word = opts.args
    if not word or word == "" then
      vim.notify("Usage: TypistIgnore <wrong>", vim.log.levels.ERROR)
      return
    end
    Store.ignore_mistake(word)
    vim.notify("Typist: ignoring '" .. word:lower() .. "'", vim.log.levels.INFO)
  end, { nargs = 1, desc = "Typist: ignore misspelling" })

  vim.api.nvim_create_user_command("TypistToggle", function()
    M.toggle()
  end, { desc = "Typist: toggle tracking" })
end

local function register_keymaps()
  -- Avoid TextAnalyzer <leader>tt — use ty / tY
  vim.keymap.set("n", "<leader>ty", function() M.stats() end, { desc = "Typist: Stats" })
  vim.keymap.set("n", "<leader>tY", function() M.toggle() end, { desc = "Typist: Toggle tracking" })
end

local function register_autocmds()
  local group = vim.api.nvim_create_augroup("Typist", { clear = true })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function()
      Tracker.start()
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function()
      Tracker.stop()
    end,
  })

  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    callback = function()
      Tracker.on_text_changed()
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      Tracker.stop()
      Store.close()
    end,
  })
end

function M.stats()
  local words = Store.top_words(10)
  local mistakes = Store.top_mistakes(10)
  local sessions = Store.recent_session_wpm(5)

  local chunks = {
    { "Typist Statistics\n", "Title" },
    {
      string.format("  Tracking: %s  │  last WPM: %.0f\n\n",
        Tracker.is_enabled() and "ON" or "OFF",
        Tracker.last_wpm() or 0),
      "Normal",
    },
  }

  table.insert(chunks, { "  Top words:\n", "Title" })
  if #words == 0 then
    table.insert(chunks, { "    (none yet — type in insert mode)\n", "Comment" })
  else
    for i, w in ipairs(words) do
      table.insert(chunks, {
        string.format("    %2d. %-20s %d×\n", i, w.word, w.count),
        "Normal",
      })
    end
  end

  table.insert(chunks, { "\n  Top mistakes:\n", "Title" })
  if #mistakes == 0 then
    table.insert(chunks, { "    (none recorded)\n", "Comment" })
  else
    for i, m in ipairs(mistakes) do
      local right = m.right and (" → " .. m.right) or ""
      table.insert(chunks, {
        string.format("    %2d. %-16s %d×%s\n", i, m.wrong, m.count, right),
        "Normal",
      })
    end
  end

  table.insert(chunks, { "\n  Recent sessions:\n", "Title" })
  if #sessions == 0 then
    table.insert(chunks, { "    (none)\n", "Comment" })
  else
    for _, s in ipairs(sessions) do
      table.insert(chunks, {
        string.format("    %.0f WPM  (%d words)  %s\n",
          s.wpm_avg or 0, s.words_typed or 0, s.started_at or ""),
        "Normal",
      })
    end
  end

  table.insert(chunks, {
    "\n  :TypistAdd <word>  :TypistIgnore <wrong>  :TypistToggle\n",
    "Comment",
  })

  vim.api.nvim_echo(chunks, false, {})
end

function M.toggle()
  local next_state = not Tracker.is_enabled()
  Tracker.set_enabled(next_state)
  vim.notify(
    "Typist: tracking " .. (next_state and "enabled" or "disabled"),
    vim.log.levels.INFO
  )
end

function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  if not M.config.db_path then
    M.config.db_path = vim.fn.stdpath("data") .. "/typist.db"
  end

  Store.setup(M.config.db_path)
  Store.init()
  Tracker.setup(M.config)

  register_autocmds()
  register_commands()
  register_keymaps()

  if M.config.cmp and M.config.cmp.enable ~= false then
    CmpSource.register(M.config.cmp)
  end

  vim.notify("Typist: loaded", vim.log.levels.DEBUG)
end

return M
