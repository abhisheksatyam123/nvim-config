# Neovim Plugin Documentation 🚀

This document explains the purpose and key features of the currently active plugins installed in your Neovim configuration (`~/.config/nvim/lua/plugins/`).

## 🎨 UI & Aesthetics

- **Catppuccin** (`catppuccin.lua`): A soothing, high-contrast color scheme. Set as the default theme.
- **Lualine** (`lualine.lua`): A fast and highly customizable statusline at the bottom of the editor. Shows file information, encoding, and your location.
- **Indent-Blankline** (`indent-blankline.lua`): Adds subtle vertical guides to indicate code indentation levels, making it easier to read deeply nested code.
- **Highlight-Colors** (`highlight-colors.lua` - *Interesting Words*): Allows you to highlight specific words in different colors to track them. Keys: `\` to search/highlight, `<leader>k` to toggle.
- **Which-Key** (`which-key.lua`): A popup bridge that helps you remember your keybindings. When you press a leader key, it shows you all available follow-up commands.

## 🔍 Navigation & Search

- **Fzf-Lua** (`fzf-lua.lua`): The primary, blazingly fast fuzzy finder for files, grep search, and buffers. Optimized to use the external `fzf` and `fd` binaries, respecting `.gitignore` and displaying filenames first.
  - `<leader>ff`: Find files (with filename first)
  - `<leader>fg`: Live grep (search text inside files)
  - `<leader>fb`: Search open buffers
  - `<leader>fh`: Search help tags
- **Telescope** (`telescope.lua`): A highly extensible fuzzy finder. Its primary global keymaps are disabled to prioritize `fzf-lua`, but it remains active as an API library/UI dependency for other plugins like Harpoon and CodeMarks.
- **Harpoon 2** (`harpoon.lua`): Allows you to "pin" your most frequently used files for instant jumping.
  - `<leader>hm`: Add file to Harpoon
  - `<leader>ha`: Toggle Harpoon list (uses Telescope UI)
  - `<leader>hn`/`<leader>hp`: Jump to next/prev Harpoon
- **Oil** (`oil.lua`): A unique file explorer that lets you edit your filesystem like a normal Neovim buffer.
  - `-` (hyphen): Open Oil explorer
- **Auto-Session** (`auto-session.lua`): Automatically saves and restores your Neovim sessions based on your working directory.
  - `<leader>wr`: Restore session
  - `<leader>ws`: Save session
- **Flash** (`flash.lua`): Lightning-fast movement tool. Type a few characters and jump directly to them.
  - `s`: Search/jump to any character on screen.

## 🛠️ Coding & LSP

- **LSP-Config & Mason** (`lsp-config.lua`):
  - **Mason**: A manager for LSP servers, formatters, and linters.
  - **LSP-Config**: Connects Neovim to these servers for features like "Go to Definition" (`gd`), "Hover info" (`K`), and "Code Actions" (`ca`).
- **Completions** (`completions.lua` - *nvim-cmp*): Provides the auto-completion popup as you type, pulling suggestions from LSP, snippets (LuaSnip), and the buffer.
- **Conform** (`conform.lua`): An efficient code formatter. It uses tools like `stylua` or `prettier` to clean up your code.
  - `<leader>mp`: Manual format
- **CodeCompanion** (`codecompanion.lua`): Your AI assistant within Neovim. It uses Gemini to provide chat and inline code suggestions.
  - `<leader>a`: AI Actions
  - `<leader>aa`: Toggle AI Chat
- **Autopairs & Autotag** (`autopairs.lua`): Essential automation that automatically closes brackets, quotes, and HTML/React tags as you type.

## 🔍 Diagnostics & Maintenance

- **Trouble** (`trouble.lua`): A centralized dashboard for all code errors and warnings (diagnostics) across the workspace.
  - `<leader>xx`: Toggle Trouble diagnostics list.
- **Todo-Comments** (`todo-comments.lua`): Highlights and lists all `TODO`, `FIXME`, `BUG`, and `NOTE` labels manually written in your codebase.
  - `<leader>st`: Search your Todo comments project-wide.

## 🐙 Git Tools

- **Gitsigns** (`gitsigns.lua`): Shows git diff markers (`+`, `-`, `~`) in the sign column (gutter). Provides actions to stage or reset specific hunks of code.
  - `]c` / `[c`: Jump to next/previous hunk.
- **Fugitive** (`fugitive.lua`): The "greatest Git wrapper of all time." Use it for `:Git` commands (blame, diff, etc.).
- **LazyGit** (`lazygit.lua`): A powerful terminal UI for managing Git repositories, run directly within Neovim.
  - `<leader>gg`: Toggle the LazyGit interface.

## 🧰 Specialized Plugins

- **CodeMarks** (`codemarks.lua`): A custom local bookmarking database. Allows you to set named code marks at specific lines and navigate back to them (handling line drift automatically).
  - `<leader>mc`: Create mark at cursor
  - `<leader>md`: Delete mark
  - `<leader>me`: Edit mark metadata
  - `<leader>fm`: Search marks (using Telescope UI)
- **Obsidian** (`obsidian.lua`): A powerful integration for Second Brain / Zettelkasten note-taking. Handles wiki-links, daily notes, and Spaced Repetition (SRS).
- **Cscope-Maps** (`cscope.lua`): Provides shortcuts for Cscope, useful for navigating large C/C++ projects by tracking callers and definitions.
  - `<leader>cs...`: Various search operations.
- **Image** (`image.lua`): Allows rendering images directly in terminal Neovim (Note: currently disabled in config).
