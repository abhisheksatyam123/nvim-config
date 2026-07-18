-- NOTE: the real `interestingwords` plugin (leisiji/interestingwords.nvim) has NO
-- setup() function. It is configured via the `vim.g.interestingwords_colors` global
-- and the `Interestingwords` user command. The keymaps below reproduce the behavior
-- you asked for: <leader>k toggle word color, <leader>K clear all,
-- n navigate forward, N navigate backward (overrides native n/N search-repeat).
return {
  "leisiji/interestingwords.nvim",
  event = "VeryLazy",
  init = function()
    -- 42 pastel (low-saturation) colors spaced by the golden angle (~137.5 deg) with
    -- lightness/saturation jitter, so consecutive highlights jump around the wheel (no gradient).
    local colors = {
      "#DEAFAF", "#B3E4C1", "#D4BBE6", "#E1DBB1", "#BADCE2", "#E1ABC9", "#C0E3B4", "#BEBCE5", "#DFC1B2", "#B7E5D4",
      "#DCADE0", "#D9E2B5", "#BDD1E4", "#E3AFBA", "#B8E4BC", "#C0AEDF", "#E1D3B6", "#BBE7E5", "#E2B0D5", "#CCE3B9",
      "#AFB7DE", "#E4B9B3", "#BBE6CD", "#D3B1E1", "#E2E2BA", "#ABD1E1", "#E3B4C7", "#C1E5BC", "#BAB2DF", "#E5CCB7",
      "#ADE0D4", "#E2B5E0", "#D7E4BD", "#AFC2E3", "#E4B8BB", "#AEDFB8", "#CCB6E1", "#E7DEBB", "#B0DDE2", "#E3B9D3",
      "#BEDEAF", "#B3B5E4",
    }
    -- Set in the main event loop: lazy's init/config context drops table-valued vim.g writes,
    -- so use vim.schedule so the assignment lands in the normal context (where it persists).
    vim.schedule(function() vim.g.interestingwords_colors = colors end)
  end,
  config = function()
    vim.keymap.set("n", "<leader>k", ":Interestingwords --toggle<CR>",
      { desc = "InterestingWords: toggle word highlight" })
    vim.keymap.set("n", "<leader>K", ":Interestingwords --remove_all<CR>",
      { desc = "InterestingWords: clear all highlights" })
    vim.keymap.set("n", "n", ":Interestingwords --navigate<CR>",
      { desc = "InterestingWords: next highlighted word" })
    vim.keymap.set("n", "N", ":Interestingwords --navigate b<CR>",
      { desc = "InterestingWords: prev highlighted word" })
  end,
}
