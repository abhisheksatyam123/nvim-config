return {
  {
    "lewis6991/gitsigns.nvim",
    config = function()
      require("gitsigns").setup({
        signs = {
          add          = { text = "┃" },
          change       = { text = "┃" },
          delete       = { text = "_" },
          topdelete    = { text = "‾" },
          changedelete = { text = "~" },
          untracked    = { text = "┆" },
        },
        signs_staged = {
          add          = { text = "┃" },
          change       = { text = "┃" },
          delete       = { text = "_" },
          topdelete    = { text = "‾" },
          changedelete = { text = "~" },
          untracked    = { text = "┆" },
        },
        -- Custom visual and functional improvements
        preview_config = {
          border = "rounded",
          style = "minimal",
          relative = "cursor",
          row = 0,
          col = 1,
        },
        current_line_blame_opts = {
          virt_text = true,
          virt_text_pos = "eol",
          delay = 500, -- Reduced delay (from 1000ms) for snappy feedback
          ignore_whitespace = false,
          virt_text_priority = 100,
        },
        current_line_blame_formatter = "    <author> • <author_time:%Y-%m-%d> • <summary>",
        on_attach = function(bufnr)
          local gitsigns = require("gitsigns")

          local function map(mode, l, r, opts)
            opts = opts or {}
            opts.buffer = bufnr
            vim.keymap.set(mode, l, r, opts)
          end

          -- Navigation
          map("n", "]c", function()
            if vim.wo.diff then
              vim.cmd.normal({ "]c", bang = true })
            else
              gitsigns.nav_hunk("next")
            end
          end, { desc = "Next Git Hunk" })

          map("n", "[c", function()
            if vim.wo.diff then
              vim.cmd.normal({ "[c", bang = true })
            else
              gitsigns.nav_hunk("prev")
            end
          end, { desc = "Previous Git Hunk" })

          -- Actions
          map("n", "<leader>hs", gitsigns.stage_hunk, { desc = "Git: Stage hunk" })
          map("n", "<leader>hr", gitsigns.reset_hunk, { desc = "Git: Reset hunk" })
          map("v", "<leader>hs", function() gitsigns.stage_hunk({ vim.fn.line("."), vim.fn.line("v") }) end, { desc = "Git: Stage selected hunk" })
          map("v", "<leader>hr", function() gitsigns.reset_hunk({ vim.fn.line("."), vim.fn.line("v") }) end, { desc = "Git: Reset selected hunk" })
          map("n", "<leader>hu", gitsigns.undo_stage_hunk, { desc = "Git: Undo stage hunk" })
          
          -- Toggle inline diff view of the entire current file
          map("n", "<leader>hp", function()
            local config = require("gitsigns.config").config
            local new_state = not config.show_deleted
            gitsigns.toggle_deleted(new_state)
            gitsigns.toggle_linehl(new_state)
            gitsigns.toggle_word_diff(new_state)
          end, { desc = "Git: Toggle inline diff of current file" })

          map("n", "<leader>hb", function() gitsigns.blame_line({ full = true }) end, { desc = "Git: Blame line (tooltip)" })
          map("n", "<leader>hc", gitsigns.show_commit, { desc = "Git: Show commit for hunk" })
          map("n", "<leader>hd", gitsigns.diffthis, { desc = "Git: Diff this (split view)" })

          -- Hunks listing & quick navigation (quickfix list)
          map("n", "<leader>hq", function() gitsigns.setqflist("attached") end, { desc = "Git: List file hunks in quickfix" })
          map("n", "<leader>hQ", function() gitsigns.setqflist("all") end, { desc = "Git: List all project hunks in quickfix" })

          -- Toggles
          map("n", "<leader>tb", gitsigns.toggle_current_line_blame, { desc = "Git: Toggle line blame (virtual text)" })

          -- Text object
          map({ "o", "x" }, "ih", ":<C-U>Gitsigns select_hunk<CR>", { desc = "Git: Inner hunk text object" })
        end
      })
    end
  }
}
