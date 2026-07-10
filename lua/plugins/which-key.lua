return {
  "folke/which-key.nvim",
  event = "VeryLazy",
  opts = {
    delay = 300,
    plugins = { spelling = { enabled = true } },
  },
  config = function(_, opts)
    local wk = require("which-key")
    wk.setup(opts)
    wk.add({
      { "<leader>t", group = "Tab" },
      { "<leader>tw", group = "Window" },
      { "<leader>l", group = "Lazy" },
      { "<leader>f", group = "Format" },
      { "<leader>e", group = "Diagnostic" },
      { "<leader>q", group = "Quickfix" },
      { "<leader>r", group = "Rename" },
      { "<leader>c", group = "Code" },
      { "<leader>i", group = "Inlay" },
      { "<leader>m", group = "Markdown" },
    })
  end,
}
