--- typist/spell.lua
--- Classify finished words as spell-good or spell-bad using Neovim spell.

local Spell = {}

local Store

local function get_store()
  if not Store then Store = require("typist.store") end
  return Store
end

--- Returns true if filetype should participate in spell learning.
function Spell.should_learn(config, ft)
  local enable = config.enable_spell_learn
  if enable == true then return true end
  if type(enable) ~= "table" then return false end
  for _, f in ipairs(enable) do
    if f == ft then return true end
  end
  return false
end

--- Check if word is spelled correctly.
--- Uses vim.spell.check when available; falls back to spellbadword.
--- @return boolean is_good
function Spell.is_good(word)
  if not word or word == "" then return true end

  -- Prefer vim.spell.check (Neovim 0.8+)
  if vim.spell and vim.spell.check then
    local ok, result = pcall(vim.spell.check, word)
    if ok and type(result) == "table" then
      -- empty => good; non-empty list of bad regions => bad
      return #result == 0
    end
  end

  -- Fallback: spellbadword returns [badword, type]
  local bad = vim.fn.spellbadword(word)
  if type(bad) == "table" then
    return bad[1] == "" or bad[1] == nil
  end
  return true
end

--- Process a finished word: learn or record mistake.
--- recent_wrong: optional previous bad word in this edit burst (for correction linking).
--- @return boolean|nil is_good (nil if skipped)
function Spell.process_word(word, config, ft, recent_wrong)
  if not word or word == "" then return nil end

  local store = get_store()

  if not Spell.should_learn(config, ft) then
    -- Still learn typed vocabulary without spell classification when disabled for ft
    if config.learn_without_spell ~= false then
      store.upsert_word(word, "typed", 1)
    end
    return true
  end

  -- Ensure spell is on for accurate checks in this buffer (local, temporary)
  local prev_spell = vim.wo.spell
  if not prev_spell then
    vim.wo.spell = true
  end

  local good = Spell.is_good(word)

  if not prev_spell then
    vim.wo.spell = false
  end

  if good then
    if recent_wrong and recent_wrong ~= "" and recent_wrong:lower() ~= word:lower() then
      store.record_correction(recent_wrong, word, ft)
    else
      store.upsert_word(word, "typed", 1)
    end
  else
    if not store.is_ignored(word) then
      store.upsert_mistake(word, ft)
    end
  end
  return good
end

return Spell
