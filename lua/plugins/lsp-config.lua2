return {
  {
    "williamboman/mason.nvim",
    lazy = false,
    config = function()
      require("mason").setup()
    end,
  },
  {
    "williamboman/mason-lspconfig.nvim",
    lazy = false,
    opts = {
      auto_install = true,
      ensure_installed = { "markdown_oxide", "ts_ls", "lua_ls", "html", "cssls", "jsonls" },
    },
  },
  {
    "neovim/nvim-lspconfig",
    lazy = false,
    config = function()
      local cmp_nvim_lsp = require("cmp_nvim_lsp")
      local capabilities = vim.tbl_deep_extend(
        "force",
        {},
        vim.lsp.protocol.make_client_capabilities(),
        cmp_nvim_lsp.default_capabilities()
      )

      vim.lsp.config("ruby_lsp", { capabilities = capabilities })
      vim.lsp.config("lua_ls", { capabilities = capabilities })
      vim.lsp.config("ts_ls", { capabilities = capabilities })
      vim.lsp.config("html", { capabilities = capabilities })
      vim.lsp.config("cssls", { capabilities = capabilities })
      vim.lsp.config("jsonls", { capabilities = capabilities })
      vim.lsp.config("markdown_oxide", {
        capabilities = vim.tbl_deep_extend("force", capabilities, {
          workspace = {
            didChangeWatchedFiles = {
              dynamicRegistration = true,
            },
          },
        }),
        root_markers = { ".git", ".obsidian", ".moxide.toml" },
      })

      vim.lsp.enable({ "ruby_lsp", "lua_ls", "ts_ls", "markdown_oxide", "html", "cssls", "jsonls" })

      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("lsp_attach", { clear = true }),
        callback = function(ev)
          local client = vim.lsp.get_client_by_id(ev.data.client_id)
          if client and client.name == "markdown_oxide" then
            vim.keymap.set("n", "gf", vim.lsp.buf.definition, { buffer = ev.buf, desc = "Go to definition" })
            vim.keymap.set("n", "<CR>", function()
              local line = vim.api.nvim_get_current_line()
              local col = vim.fn.col(".")

              local wiki_start, wiki_end, wiki_heading = line:find("%[%[#([^%]]+)%]%]")
              if wiki_start and col >= wiki_start and col <= wiki_end then
                local heading_pat = vim.fn.escape(wiki_heading, "\\/.*$^~[]")
                vim.fn.search("^#\\+\\s\\+" .. heading_pat, "w")
                return
              end

              local md_start, md_end, md_heading = line:find("%[[^%]]+%]%(#([^%)]+)%)")
              if md_start and col >= md_start and col <= md_end then
                local unslugged = md_heading:gsub("-", " ")
                local heading_pat = vim.fn.escape(unslugged, "\\/.*$^~[]")
                vim.fn.search("^#\\+\\s\\+" .. heading_pat, "iw")
                return
              end

              local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
              client:request("textDocument/definition", params, function(err, result)
                vim.schedule(function()
                  if not err and result and not (vim.islist(result) and #result == 0) then
                    if vim.islist(result) then
                      vim.lsp.util.jump_to_location(result[1], client.offset_encoding)
                    else
                      vim.lsp.util.jump_to_location(result, client.offset_encoding)
                    end
                  else
                    vim.lsp.buf.code_action({ apply = true })
                  end
                end)
              end, ev.buf)
            end, { buffer = ev.buf, desc = "Smart follow link or create note" })
            vim.api.nvim_create_user_command("Daily", function(args)
              vim.lsp.buf.execute_command({ command = "jump", arguments = { args.args } })
            end, { desc = "Open daily note", nargs = "*" })
          end
        end,
      })

      vim.keymap.set("n", "K", vim.lsp.buf.hover, {})
      vim.keymap.set("n", "<leader>gd", vim.lsp.buf.definition, {})
      vim.keymap.set("n", "<leader>gr", vim.lsp.buf.references, {})
      vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, {})
      vim.keymap.set("n", "<leader>gf", vim.lsp.buf.format, {})
      vim.keymap.set("n", "<space>rn", vim.lsp.buf.rename, {})
    end,
  },
}
