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
        vim.keymap.set("n", "<leader>mc", function() codemarks.create_mark() end,  { desc = "CodeMarks: Create mark at cursor" })
        vim.keymap.set("n", "<leader>md", function() codemarks.delete_mark() end,  { desc = "CodeMarks: Delete mark" })
        vim.keymap.set("n", "<leader>me", function() codemarks.edit_mark() end,    { desc = "CodeMarks: Edit mark metadata" })
        vim.keymap.set("n", "<leader>fm", function() codemarks.search_marks() end, { desc = "CodeMarks: Search/jump/delete marks (Fzf-Lua)" })

        -- Refresh gutter signs whenever a file is loaded into a buffer
        vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
          callback = function(args)
            codemarks.refresh_signs(args.buf)
          end,
          desc = "CodeMarks: render gutter signs for marks in this file",
        })

        -- Track line drift and refresh signs on every save
        vim.api.nvim_create_autocmd("BufWritePost", {
          callback = function(args)
            codemarks.update_line_drift(args.buf)
          end,
          desc = "CodeMarks: update line numbers if code drifted",
        })
      else
        vim.notify("CodeMarks: failed to load codemarks module", vim.log.levels.ERROR)
      end

      -- 2. Setup TextAnalyzer
      local default_config = {
        auto_load = {},
        enable_filetypes = { "log", "txt" },
        lighten_buffers = true,
        context_lines = 25,
        max_results = 10000,
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
