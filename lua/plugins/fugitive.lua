return {
  {
    "tpope/vim-fugitive",
    cmd = { "Git", "G", "Gdiffsplit", "Gvdiffsplit", "Gread", "Gwrite", "Ggrep", "Glgrep", "Gclog", "Gllog" },
    keys = {
      { "<leader>gs", "<cmd>Git<CR>", desc = "Git: Status window" },
    },
  }
}
