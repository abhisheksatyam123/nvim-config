---
id: plugins
aliases:
  - Neovim Plugin & Shortcuts Documentation 🚀
tags: []
description: Notes about plugins
---
# Neovim Plugin & Shortcuts Documentation 🚀

## Index

- [⚙️ Core Neovim Mappings (from `init.lua`)](#core-neovim-mappings-from-initlua)
  - [Tab Management](#tab-management)
  - [Window / Pane Management](#window-pane-management)
- [🎨 Colorscheme & UI](#colorscheme-ui)
  - [Catppuccin (`lua/plugins/catppuccin.lua`)](#catppuccin-luapluginscatppuccinlua)
- [🔍 Navigation & Search](#navigation-search)
  - [Fzf-Lua (`lua/plugins/fzf-lua.lua`)](#fzf-lua-luapluginsfzf-lualua)
  - [Harpoon 2 (`lua/plugins/harpoon.lua`)](#harpoon-2-luapluginsharpoonlua)
  - [Oil (`lua/plugins/oil.lua`)](#oil-luapluginsoillua)
  - [Code Marks (`lua/plugins/custom-local-plugins.lua` and `lua/codemarks.lua`)](#code-marks-luapluginscustom-local-pluginslua-and-luacodemarkslua)
  - [Text Analyzer (`lua/plugins/custom-local-plugins.lua` and `lua/text-analyzer/`)](#text-analyzer-luapluginscustom-local-pluginslua-and-luatext-analyzer)
- [🛠️ Coding, LSP & Syntax](#coding-lsp-syntax)
  - [LSP Config & Mason (`lua/plugins/lsp-config.lua`)](#lsp-config-mason-luapluginslsp-configlua)
    - [Common LSP Attach Keymaps (Active in Buffers with Running LSP)](#common-lsp-attach-keymaps-active-in-buffers-with-running-lsp)
    - [Markdown Oxide Specific Keymaps (PKM Markdown LSP)](#markdown-oxide-specific-keymaps-pkm-markdown-lsp)
- [🐙 Git Integration](#git-integration)
  - [Gitsigns (`lua/plugins/gitsigns.lua`)](#gitsigns-luapluginsgitsignslua)
- [📝 Notes & Spaced Repetition (Obsidian)](#notes-spaced-repetition-obsidian)
  - [Obsidian.nvim (`lua/plugins/obsidian.lua`)](#obsidiannvim-luapluginsobsidianlua)
- [🔗 local / Specialized Plugins](#local-specialized-plugins)
  - [RelationWindow (`plugin/relation_window.lua`)](#relationwindow-pluginrelationwindowlua)

This document lists all active plugins and their configured keyboard shortcuts, commands, and options in your Neovim setup.

---

## ⚙️ Core Neovim Mappings (from `init.lua`)

These mappings manage standard Neovim tab pages and window splits.

### Tab Management
All tab commands are prefixed by `\` (the global leader key).

| Shortcut | Description |
|---|---|
| `\ttc` | Create a new tab page |
| `\ttx` | Close the current tab page |
| `\ttn` | Go to the next tab page |
| `\ttp` | Go to the previous tab page |
| `\tt1` .. `\tt9` | Jump directly to tab pages 1 through 9 |

### Window / Pane Management
All window commands are prefixed by `\tw` (tab window prefix).

| Shortcut | Description |
|---|---|
| `\twx` | Close the current window/pane |
| `\tw%` | Split window horizontally |
| `\tw"` | Split window vertically |
| `\twh` | Move cursor to the window on the left |
| `\twj` | Move cursor to the window below |
| `\twk` | Move cursor to the window above |
| `\twl` | Move cursor to the window on the right |
| `\tw2` .. `\tw9` | Jump directly to window 1 through 9 |

[[mark:core-neovim]]

---

## 🎨 Colorscheme & UI

### Catppuccin (`lua/plugins/catppuccin.lua`)
* **Purpose**: Soothing high-contrast colorscheme configured with custom overrides for float surfaces (hover, diagnostics, signature help).
* **Shortcuts**: None (colorscheme is automatically loaded on startup).

---

## 🔍 Navigation & Search

### Fzf-Lua (`lua/plugins/fzf-lua.lua`)
* **Purpose**: The primary, blazingly fast fuzzy finder for files, grep search, and buffers. Optimized to use the external `fzf` and `fd` binaries, respecting `.gitignore` and displaying filenames first.

| Shortcut | Mode | Description |
|---|---|---|
| `<leader>ff` | Normal | Find files (uses `fd`, filename first) |
| `<leader>fg` | Normal | Live grep (search text inside files using `rg`) |
| `<leader>fb` | Normal | Search open buffers |
| `<leader>fh` | Normal | Search help tags |

### Harpoon 2 (`lua/plugins/harpoon.lua`)
* **Purpose**: Bookmarking system to pin files and quickly jump between them using a native, high-performance editor menu.

| Shortcut | Mode | Description |
|---|---|---|
| `<leader>ha` | Normal | Open Harpoon native quick menu split window |
| `<leader>hm` | Normal | Add current file to Harpoon |
| `<leader>hn` | Normal | Navigate to the next Harpoon item |
| `<leader>hp` | Normal | Navigate to the previous Harpoon item |

### Oil (`lua/plugins/oil.lua`)
* **Purpose**: Filesystem manager editing directories like standard text buffers.

| Shortcut | Mode | Description |
|---|---|---|
| `-` | Normal | Toggle floating file explorer (Oil) |

[[mark:harpoon]]

### Code Marks (`lua/plugins/custom-local-plugins.lua` and `lua/codemarks.lua`)
* **Purpose**: A custom SQLite-based code bookmarking system. Marks are stored in a centralized database (`~/.codemarks.db`), allowing you to link to code marks from your Markdown notes and jump to the code using standard navigation keys (`gd`, `gf`, `<CR>`).
* **Key Features**:
  - **Fzf-Lua Search integration** (replaced Telescope): blazingly fast filtering with live previews.
  - **Whitespace & Space Support**: Mark names can contain spaces, hyphens, and underscores.
  - **Dynamic Link Resolution Highlighting** (Resolved links turn yellow, unresolved stay gray).

| Shortcut | Mode | Description |
|---|---|---|
| `<leader>mc` | Normal | Create a Code Mark at the cursor position (prompts for name) |
| `<leader>md` | Normal | Delete a Code Mark (prompts or deletes the mark under cursor) |
| `<leader>me` | Normal | Edit a Code Mark (rename it or edit its description metadata) |
| `<leader>fm` | Normal | Search all Code Marks using Fzf-Lua |
| `gd` / `gf` / `<CR>` | Normal | In Markdown files, jump directly to the source code if cursor is on a Code Mark reference |

### Text Analyzer (`lua/plugins/custom-local-plugins.lua` and `lua/text-analyzer/`)
* **Purpose**: A custom high-performance log and text filtering and highlighting plugin designed specifically for `.log` and `.txt` files.
* **Key Features**:
  - **Buffer Lightening**: Automatically detaches LSP, stops Treesitter, and clears paren matching on file load for near-instant rendering on 1M+ lines files.
  - **Command-line first design**: Add, toggle, delete, and list filters instantly using Ex-commands without flashy floating overlays.
  - **Vertical Sidebar Panel**: Standard right-side split buffer to manage filters with Vim motions.

| Shortcut / Command | Mode | Description |
|---|---|---|
| `<leader>ta` | Normal | Open / close the Filter Manager split window panel |
| `<leader>tf` | Normal | Quick-add a new filter at the cursor position (prompts for pattern) |
| `<leader>tt` | Normal | Toggle TextAnalyzer filtering active/inactive |
| `<leader>ts` | Normal | Echo statistics (total, visible, hidden, match counts) to command line |
| `<leader>tl` | Normal | Echo color legend to command line |
| `<leader>tr` | Normal | Reset (clear) all filters in the current buffer |
| `:TA [pattern] [color] [invert]` | Command | Add filter with args (e.g. `:TA ERROR Red`, `:TA debug blue invert`) |
| `:TAList` | Command | Echo active filters list with their highlight colors |
| `:TADel <index>` | Command | Delete active filter by list index (e.g. `:TADel 1`) |
| `:TATog <index>` | Command | Toggle active filter enabled status by index (e.g. `:TATog 1`) |
| `:TAFilterSave <name>` | Command | Save current filters under `~/.config/nvim/textanalyzer/filters/<name>.json` |
| `:TAFilterLoad <name>` | Command | Load a saved filter set |
| `:TAFilterMerge <name>` | Command | Merge a saved filter set into the current buffer |
| `:TAWorkspaceSave <name>`| Command | Save full workspace (active file, active filters, and scroll position) |
| `:TAWorkspaceLoad <name>`| Command | Restore a saved workspace |

---

## 🛠️ Coding, LSP & Syntax

### LSP Config & Mason (`lua/plugins/lsp-config.lua`)
* **Purpose**: Manages and configures Language Server Protocol (LSP) integrations. Automates installation via Mason (`lua_ls`, `html`, `cssls`, `jsonls`, `ts_ls`, `clangd`).

#### Common LSP Attach Keymaps (Active in Buffers with Running LSP)
| Shortcut | Mode | Description |
|---|---|---|
| `gd` | Normal | Go to definition (clangd falls back to smart grep patterns if index is stale) |
| `gD` | Normal | Go to declaration |
| `gr` | Normal | Find all references |
| `gi` | Normal | Go to implementation |
| `gt` | Normal | Go to type definition |
| `K` | Normal | Hover documentation details |
| `<C-k>` | Normal, Insert | Show signature help |
| `<leader>ca` | Normal | Execute code action |
| `<leader>rn` | Normal | Rename symbol |
| `<leader>f` | Normal | Format document (async) |
| `[d` | Normal | Jump to previous diagnostic |
| `]d` | Normal | Jump to next diagnostic |
| `<leader>e` | Normal | Show diagnostic float tooltip |
| `<leader>q` | Normal | Open buffer diagnostics in location list |
| `<leader>ih` | Normal | Toggle inlay hints |

#### Markdown Oxide Specific Keymaps (PKM Markdown LSP)
| Shortcut | Mode | Description |
|---|---|---|
| `gf` | Normal | Follow link (markdown wikilink) |
| `<CR>` | Normal | Follow link under cursor or trigger code action to create new note |
| `<leader>ms` | Normal | Search vault symbols (workspace symbol search) |
| `<leader>mr` | Normal | Find references to vault symbol |
| `<leader>ml` | Normal | Refresh markdown code lens (reference counts) |
| `<leader>md` | Normal | Open today's daily note |

* **User Commands**: `:Daily <date>` (e.g. `:Daily tomorrow`, `:Daily yesterday`, `:Daily monday`).

---

## 🐙 Git Integration

### Gitsigns (`lua/plugins/gitsigns.lua`)
* **Purpose**: Show git diff decorations in the sign column (gutter) and run staging/resetting actions.

| Shortcut | Mode | Description |
|---|---|---|
| `]c` | Normal | Navigate to the next hunk |
| `[c` | Normal | Navigate to the previous hunk |
| `<leader>hs` | Normal, Visual | Stage current hunk / visual selection |
| `<leader>hr` | Normal, Visual | Reset current hunk / visual selection |
| `<leader>hu` | Normal | Undo stage hunk |
| `<leader>hp` | Normal | Toggle inline diff of current file |
| `<leader>hb` | Normal | Blame current line details in a tooltip window |
| `<leader>hc` | Normal | Show commit details for the hunk under cursor |
| `<leader>hd` | Normal | Diff current buffer against index (split view) |
| `<leader>hq` | Normal | Populate quickfix list with all hunks in current buffer |
| `<leader>hQ` | Normal | Populate quickfix list with all hunks across the project |
| `<leader>tb` | Normal | Toggle current line git blame virtual text |
| `ih` | Visual, Operator-Pending | Target inner hunk text object |

---

## 📝 Notes & Spaced Repetition (Obsidian)

### Obsidian.nvim (`lua/plugins/obsidian.lua`)
* **Purpose**: Spaced Repetition System (SRS) cards review and task status management using local custom fork (`obsidian.nvim_abhi`). Integrates with `~/notes` workspace.

#### Spaced Repetition System (SRS) Keymaps
| Shortcut | Mode | Description |
|---|---|---|
| `<leader>osr` | Normal | Start SRS review session for due flashcards |
| `<leader>osd` | Normal | List all due flashcards |
| `<leader>oss` | Normal | Show SRS progress statistics |
| `<leader>osb` | Normal | Browse all SRS cards in the vault |

#### Task Management & Checkbox Status Keymaps
| Shortcut | Mode | Description |
|---|---|---|
| `<leader>ott` | Normal | Toggle task checkbox status (`[ ]` -> `[/]` -> `[x]`, etc.) |
| `<leader>otd` | Normal | Mark task as Done (`[x]`) |
| `<leader>otb` | Normal | Mark task as Blocked (`[?]`) |
| `<leader>otc` | Normal | Cancel task (`[-]`) |
| `<leader>otp` | Normal | Pause all active tasks |
| `<leader>otD` | Normal | Open task dashboard split |
| `<leader>ots` | Normal | Show daily task statistics |

#### Task Priority Keymaps
| Shortcut | Mode | Description |
|---|---|---|
| `<leader>tp` | Normal | Cycle task priority |
| `<leader>t1` | Normal | Set task priority to 1 |
| `<leader>t2` | Normal | Set task priority to 2 |
| `<leader>t3` | Normal | Set task priority to 3 |
| `<leader>t.` | Normal | Defer task |

---

## 🔗 local / Specialized Plugins

### RelationWindow (`plugin/relation_window.lua`)
* **Purpose**: Interactive backlink/forward-link terminal UI graph for markdown notes vault.

| Shortcut | Mode | Description |
|---|---|---|
| `<leader>rs` | Normal | Open relation window in a horizontal split (incoming mode) |
| `<leader>rt` | Normal | Open relation window in a new tab (incoming mode) |
| `<leader>rr` | Normal | Refresh relation window |
| `<leader>ri` | Normal | Set relation window mode to incoming and refresh |
| `<leader>ro` | Normal | Set relation window mode to outgoing and refresh |
| `<leader>rx` | Normal | Toggle relation window split |
| `<leader>rm` | Normal | Switch mode (incoming ↔ outgoing) and refresh |
| `<leader>rc` | Normal | Close current relation window |
| `<leader>rC` | Normal | Close all relation window sessions |
| `<leader>rl` | Normal | List active relation window sessions |
| `<leader>rd` | Normal | Run relation window doctor diagnostic check |

