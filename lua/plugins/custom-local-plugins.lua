return {
  {
    "kkharji/sqlite.lua",
  },
  {
    dir = "/home/abhi/.config/nvim",
    name = "custom-local-plugins",
    dependencies = {
      "kkharji/sqlite.lua",
      "ibhagwan/fzf-lua",
    },
    event = { "BufReadPre", "BufNewFile" },
    config = function()
      -- 1. Setup Codemarks
      local ok_cm, codemarks = pcall(require, "codemarks")
      if ok_cm then
        vim.keymap.set("n", "<leader>mc", function() codemarks.create_mark() end, { desc = "CodeMarks: Create mark at cursor" })
        vim.keymap.set("n", "<leader>md", function() codemarks.delete_mark() end, { desc = "CodeMarks: Delete mark" })
        vim.keymap.set("n", "<leader>me", function() codemarks.edit_mark() end, { desc = "CodeMarks: Edit mark metadata" })
        vim.keymap.set("n", "<leader>fm", function() codemarks.search_marks() end, { desc = "CodeMarks: Search marks (Fzf-Lua)" })

        vim.api.nvim_create_autocmd("BufWritePost", {
          callback = function(args)
            codemarks.update_line_drift(args.buf)
          end
        })
      else
        vim.notify("TextAnalyzer: failed to load codemarks module", vim.log.levels.ERROR)
      end

      -- 2. Setup TextAnalyzer
      local default_config = {
        auto_load = {},
        enable_filetypes = { "log", "txt" },
        lighten_buffers = true,
      }
      local user_config = vim.g.text_analyzer_config or {}
      local opts = vim.tbl_deep_extend("keep", user_config, default_config)

      local ok_ta, ta = pcall(require, "text-analyzer")
      if ok_ta then
        ta.setup(opts)
        vim.g.text_analyzer_loaded = true
      else
        vim.notify("TextAnalyzer: failed to load text-analyzer module", vim.log.levels.ERROR)
      end
    end,
  }
}
