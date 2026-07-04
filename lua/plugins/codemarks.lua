local function normalize_key(key)
  local k = key:lower()
  if k == "<cr>" or k == "\r" or k == "<enter>" then
    return "<cr>"
  end
  return k
end

local function get_existing_map(bufnr, lhs, desc_to_ignore)
  local norm_target = normalize_key(lhs)

  -- Check buffer maps
  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  for _, map in ipairs(maps) do
    if normalize_key(map.lhs) == norm_target and map.desc ~= desc_to_ignore then
      return map
    end
  end
  -- Check global maps
  local global_maps = vim.api.nvim_get_keymap("n")
  for _, map in ipairs(global_maps) do
    if normalize_key(map.lhs) == norm_target and map.desc ~= desc_to_ignore then
      return map
    end
  end
  return nil
end

local function execute_fallback(map, default_fallback)
  if map then
    if map.callback then
      map.callback()
    elseif map.rhs then
      local keys = vim.api.nvim_replace_termcodes(map.rhs, true, false, true)
      local mode = (map.noremap == 1 or map.noremap == true) and "n" or "m"
      vim.api.nvim_feedkeys(keys, mode, false)
    end
  elseif default_fallback then
    default_fallback()
  end
end

local function setup_markdown_mappings(bufnr)
  local codemarks = require("codemarks")
  
  -- Initialize buffer local fallback storage if not present
  if not vim.b[bufnr].codemarks_fallback_gd then
    vim.b[bufnr].codemarks_fallback_gd = get_existing_map(bufnr, "gd", "Go to definition/mark")
  end
  if not vim.b[bufnr].codemarks_fallback_gf then
    vim.b[bufnr].codemarks_fallback_gf = get_existing_map(bufnr, "gf", "Follow link/mark")
  end
  if not vim.b[bufnr].codemarks_fallback_cr then
    vim.b[bufnr].codemarks_fallback_cr = get_existing_map(bufnr, "<CR>", "Follow link/mark or create note")
  end

  vim.keymap.set("n", "gd", function()
    local mark = codemarks.get_mark_under_cursor()
    if mark then
      codemarks.goto_mark(mark)
    else
      execute_fallback(vim.b[bufnr].codemarks_fallback_gd, vim.lsp.buf.definition)
    end
  end, { buffer = bufnr, desc = "Go to definition/mark" })

  vim.keymap.set("n", "gf", function()
    local mark = codemarks.get_mark_under_cursor()
    if mark then
      codemarks.goto_mark(mark)
    else
      execute_fallback(vim.b[bufnr].codemarks_fallback_gf, vim.lsp.buf.definition)
    end
  end, { buffer = bufnr, desc = "Follow link/mark" })

  vim.keymap.set("n", "<CR>", function()
    local mark = codemarks.get_mark_under_cursor()
    if mark then
      codemarks.goto_mark(mark)
    else
      execute_fallback(vim.b[bufnr].codemarks_fallback_cr, function()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
      end)
    end
  end, { buffer = bufnr, desc = "Follow link/mark or create note" })
end

return {
  {
    "kkharji/sqlite.lua",
  },
  {
    "nvim-telescope/telescope.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
  },
  {
    dir = "/home/abhi/.config/nvim",
    name = "codemarks",
    dependencies = {
      "kkharji/sqlite.lua",
      "nvim-telescope/telescope.nvim",
    },
    config = function()
      local codemarks = require("codemarks")

      -- Mappings in standard buffers
      vim.keymap.set("n", "<leader>mc", function() require("codemarks").create_mark() end, { desc = "CodeMarks: Create mark at cursor" })
      vim.keymap.set("n", "<leader>md", function() require("codemarks").delete_mark() end, { desc = "CodeMarks: Delete mark" })
      vim.keymap.set("n", "<leader>me", function() require("codemarks").edit_mark() end, { desc = "CodeMarks: Edit mark metadata" })
      vim.keymap.set("n", "<leader>fm", function() require("codemarks").search_marks() end, { desc = "CodeMarks: Search marks (Telescope)" })

      -- Autocmd to handle line drift on buffer write
      vim.api.nvim_create_autocmd("BufWritePost", {
        callback = function(args)
          require("codemarks").update_line_drift(args.buf)
        end
      })

      -- Autocmd to map navigation in markdown files
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "markdown",
        callback = function(args)
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(args.buf) then
              setup_markdown_mappings(args.buf)
            end
          end)
        end
      })

      -- Autocmd to map navigation when markdown_oxide LSP attaches
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(ev)
          local client = vim.lsp.get_client_by_id(ev.data.client_id)
          if client and client.name == "markdown_oxide" then
            vim.schedule(function()
              if vim.api.nvim_buf_is_valid(ev.buf) then
                setup_markdown_mappings(ev.buf)
              end
            end)
          end
        end
      })
    end
  }
}
