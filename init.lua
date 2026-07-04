vim.g.mapleader = "\\"
vim.g.maplocalleader = "\\"

-- Window/tab mappings (leader + vt/vw prefix):
-- Tabs: \vtc create, \vtx close, \vtn next, \vtp previous, \vt1..\vt9 jump
-- Windows: \vwx close, \vw% horizontal split, \vw" vertical split
--          \vwh/\vwj/\vwk/\vwl move, \vw1..\vw9 jump
vim.keymap.set("n", "<leader>ttc", "<cmd>tabnew<CR>", { desc = "Tab: create" })
vim.keymap.set("n", "<leader>ttx", "<cmd>tabclose<CR>", { desc = "Tab: close" })
vim.keymap.set("n", "<leader>ttn", "<cmd>tabnext<CR>", { desc = "Tab: next" })
vim.keymap.set("n", "<leader>ttp", "<cmd>tabprevious<CR>", { desc = "Tab: previous" })

vim.keymap.set("n", "<leader>twx", "<cmd>close<CR>", { desc = "Window: close pane" })
vim.keymap.set("n", "<leader>tw%", "<cmd>split<CR>", { desc = "Window: horizontal split" })
vim.keymap.set("n", '<leader>tw"', "<cmd>vsplit<CR>", { desc = "Window: vertical split" })
vim.keymap.set("n", "<leader>twh", "<C-w>h", { desc = "Window: left" })
vim.keymap.set("n", "<leader>twj", "<C-w>j", { desc = "Window: down" })
vim.keymap.set("n", "<leader>twk", "<C-w>k", { desc = "Window: up" })
vim.keymap.set("n", "<leader>twl", "<C-w>l", { desc = "Window: right" })
for i = 1, 9 do
  local function jump_to_window()
    local wins = vim.api.nvim_tabpage_list_wins(0)
    local target = wins[i]
    if target and vim.api.nvim_win_is_valid(target) then
      vim.api.nvim_set_current_win(target)
    else
      vim.notify("Window " .. i .. " does not exist in current tab", vim.log.levels.WARN)
    end
  end
  vim.keymap.set("n", "<leader>tw" .. i, jump_to_window, { desc = "Window: jump to " .. i })
  vim.keymap.set("n", "<leader>tt" .. i, "<cmd>tabnext " .. i .. "<CR>", { desc = "Tab: jump to " .. i })
end

vim.opt.clipboard = "unnamedplus"
vim.opt.signcolumn = "yes"
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.swapfile = false
vim.opt.termguicolors = true
-- conceallevel: keep at 0 globally to avoid treesitter conceal_line errors on
-- non-markdown buffers. Vault markdown buffers set local conceallevel=2 in
-- plugins/obsidian.lua so Obsidian UI extmarks can render checkboxes/icons.
vim.opt.conceallevel = 0
vim.wo.number = true
vim.opt.timeoutlen = 1000
-- Global border style for floating windows (Neovim 0.11+).
-- nvim-cmp's bordered() helper reads this option.
vim.o.winborder = "double"



-- Treesitter occasionally throws extmark range errors on terminal buffers.
-- RelationWindow uses :termopen(), so keep TS disabled for terminal windows.
vim.api.nvim_create_autocmd("TermOpen", {
  callback = function(args)
    -- Keep relation/terminal buffers out of code LSP hint pipelines.
    pcall(vim.api.nvim_set_option_value, "filetype", "relationwindow", { buf = args.buf })
    pcall(function()
      if vim.lsp.inlay_hint and vim.lsp.inlay_hint.enable then
        vim.lsp.inlay_hint.enable(false, { bufnr = args.buf })
      end
    end)
    pcall(function()
      local clients = vim.lsp.get_clients({ bufnr = args.buf })
      for _, client in ipairs(clients) do
        vim.lsp.buf_detach_client(args.buf, client.id)
      end
    end)
    pcall(vim.treesitter.stop, args.buf)
  end,
})


-- Compatibility patch for Neovim 0.11+ (ft_to_lang was removed)
-- Forced definition to ensure Telescope never sees a nil value
if vim.treesitter then
  vim.treesitter.ft_to_lang = function(ft)
    local ok, lang = pcall(function() return vim.treesitter.language.get_lang(ft) end)
    return (ok and lang) or ft
  end
end

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    { import = "plugins" },
  },
})

-- RelationWindow commands and mappings are loaded from:
--   ~/.config/nvim/plugin/relation_window.lua
