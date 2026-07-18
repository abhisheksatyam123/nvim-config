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
      { "<leader>t", group = "Tab / TextAnalyzer" },
      { "<leader>tw", group = "Window" },
      { "<leader>y", group = "Typist" },
      { "<leader>l", group = "Lazy" },
      { "<leader>f", group = "Find / Format" },
      { "<leader>e", group = "Diagnostic" },
      { "<leader>q", group = "Quickfix" },
      { "<leader>r", group = "Rename" },
      { "<leader>c", group = "Code" },
      { "<leader>i", group = "Inlay" },
      { "<leader>m", group = "Markdown / CodeMarks" },
    })
  end,
}
