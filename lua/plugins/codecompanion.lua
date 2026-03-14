return {
  "olimorris/codecompanion.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
  },
  config = function()
    require("codecompanion").setup({
      strategies = {
        chat = {
          adapter = "gemini",
        },
        inline = {
          adapter = "gemini",
        },
      },
    })
    
    vim.keymap.set({"n", "v"}, "<leader>a", "<cmd>CodeCompanionActions<cr>", { noremap = true, silent = true, desc = "CodeCompanion actions" })
    vim.keymap.set({"n", "v"}, "<leader>aa", "<cmd>CodeCompanionChat Toggle<cr>", { noremap = true, silent = true, desc = "Toggle AI chat" })
  end,
}
