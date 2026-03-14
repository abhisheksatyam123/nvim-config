return {
  dir = "/local/mnt/workspace/qprojects/obsidian.nvim_abhi",
  name = "obsidian.nvim",
  lazy = true,
  ft = "markdown",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("obsidian").setup({
      workspaces = {
        {
          name = "personal",
          path = "/local/mnt/workspace/notes",
        },
      },

      note_id_func = function(title)
        return title
      end,

      wiki_link_func = function(opts)
        return require("obsidian.util").wiki_link_id_prefix(opts)
      end,

      markdown_link_func = function(opts)
        return require("obsidian.util").markdown_link(opts)
      end,

      note_frontmatter_func = function(note)
        if note.title then
          note:add_alias(note.title)
        end

        local out = { id = note.id, aliases = note.aliases, tags = note.tags }

        if note.metadata ~= nil and not vim.tbl_isempty(note.metadata) then
          for k, v in pairs(note.metadata) do
            out[k] = v
          end
        end

        return out
      end,

      -- Task Management Configuration
      tasks = {
        enabled = true,
        auto_pause_on_exit = true,
        stale_threshold_days = 3,
        daily_stats_placeholder = "<!-- obsidian-task-stats -->",
      },

      -- UI checkboxes for all task states
      ui = {
        enable = true,
        update_debounce = 200,
        max_file_length = 5000,
        checkboxes = {
          [" "] = { char = "󰄱", hl_group = "ObsidianTodo" },
          ["/"] = { char = "🟢", hl_group = "ObsidianActive" },
          ["|"] = { char = "⏸", hl_group = "ObsidianPaused" },
          ["?"] = { char = "🚧", hl_group = "ObsidianBlocked" },
          ["-"] = { char = "❌", hl_group = "ObsidianCancelled" },
          ["x"] = { char = "✅", hl_group = "ObsidianDone" },
        },
        hl_groups = {
          ObsidianTodo = { bold = true, fg = "#f78c6c" },
          ObsidianActive = { bold = true, fg = "#89ddff" },
          ObsidianPaused = { bold = true, fg = "#ffcb6b" },
          ObsidianBlocked = { bold = true, fg = "#ff5370" },
          ObsidianCancelled = { bold = true, fg = "#676e95" },
          ObsidianDone = { bold = true, fg = "#c3e88d" },
          ObsidianP1 = { bold = true, fg = "#ff5370" },
          ObsidianP2 = { bold = true, fg = "#ffcb6b" },
          ObsidianP3 = { bold = true, fg = "#89ddff" },
          ObsidianDeferred = { italic = true, fg = "#676e95" },
        },
      },
    })

    -- SRS Keymaps
    vim.keymap.set("n", "<leader>osr", "<cmd>ObsidianSRSReview<cr>",
      { noremap = true, silent = true, desc = "SRS: Review due flashcards" })
    vim.keymap.set("n", "<leader>osd", "<cmd>ObsidianSRSDue<cr>",
      { noremap = true, silent = true, desc = "SRS: List due flashcards" })
    vim.keymap.set("n", "<leader>oss", "<cmd>ObsidianSRSStats<cr>",
      { noremap = true, silent = true, desc = "SRS: Show statistics" })
    vim.keymap.set("n", "<leader>osb", "<cmd>ObsidianSRSBrowse<cr>",
      { noremap = true, silent = true, desc = "SRS: Browse all cards" })

    -- Task Management Keymaps
    vim.keymap.set("n", "<leader>ott", "<cmd>ObsidianTaskToggle<cr>",
      { noremap = true, silent = true, desc = "Task: Smart toggle state" })
    vim.keymap.set("n", "<leader>otd", "<cmd>ObsidianTaskToggle done<cr>",
      { noremap = true, silent = true, desc = "Task: Mark done" })
    vim.keymap.set("n", "<leader>otb", "<cmd>ObsidianTaskToggle blocked<cr>",
      { noremap = true, silent = true, desc = "Task: Mark blocked" })
    vim.keymap.set("n", "<leader>otc", "<cmd>ObsidianTaskToggle cancel<cr>",
      { noremap = true, silent = true, desc = "Task: Cancel" })
    vim.keymap.set("n", "<leader>otp", "<cmd>ObsidianTaskPauseAll<cr>",
      { noremap = true, silent = true, desc = "Task: Pause all active" })
    vim.keymap.set("n", "<leader>otD", "<cmd>ObsidianTaskDashboard<cr>",
      { noremap = true, silent = true, desc = "Task: Open dashboard" })
    vim.keymap.set("n", "<leader>ots", "<cmd>ObsidianTaskStats<cr>",
      { noremap = true, silent = true, desc = "Task: Show daily stats" })

    -- Priority Keymaps
    vim.keymap.set("n", "<leader>tp", "<cmd>ObsidianTaskPriority<cr>",
      { noremap = true, silent = true, desc = "Task: Cycle priority" })
    vim.keymap.set("n", "<leader>t1", "<cmd>ObsidianTaskPriority 1<cr>",
      { noremap = true, silent = true, desc = "Task: Set P1" })
    vim.keymap.set("n", "<leader>t2", "<cmd>ObsidianTaskPriority 2<cr>",
      { noremap = true, silent = true, desc = "Task: Set P2" })
    vim.keymap.set("n", "<leader>t3", "<cmd>ObsidianTaskPriority 3<cr>",
      { noremap = true, silent = true, desc = "Task: Set P3" })
    vim.keymap.set("n", "<leader>t.", "<cmd>ObsidianTaskPriority defer<cr>",
      { noremap = true, silent = true, desc = "Task: Defer" })
  end,
}
