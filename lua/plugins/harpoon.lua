return {
  "ThePrimeagen/harpoon",
  branch = "harpoon2",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    local harpoon = require("harpoon")
    harpoon:setup()

    -- Toggle quick menu (native UI buffer, extremely fast)
    vim.keymap.set("n", "<leader>ha", function() harpoon.ui:toggle_quick_menu(harpoon:list()) end,
      { desc = "Open harpoon window" })

    vim.keymap.set("n", "<leader>hm", function() harpoon:list():add() end,
      { desc = "Add file to harpoon" })

    -- Basic navigation
    vim.keymap.set("n", "<leader>hn", function() harpoon:list():next() end, { desc = "Next harpoon" })
    vim.keymap.set("n", "<leader>hp", function() harpoon:list():prev() end, { desc = "Previous harpoon" })
  end
}
