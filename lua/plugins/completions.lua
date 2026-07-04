return {
  {
    "hrsh7th/cmp-nvim-lsp"
  },
  {
    "L3MON4D3/LuaSnip",
    dependencies = {
      "saadparwaiz1/cmp_luasnip",
      "rafamadriz/friendly-snippets",
    },
  },
  {
    "hrsh7th/nvim-cmp",
    version = false,
    config = function()
      local cmp = require("cmp")
      require("luasnip.loaders.from_vscode").lazy_load()

      local cmp_border = {
        { "┌", "CmpBorder" },
        { "─", "CmpBorder" },
        { "┐", "CmpBorder" },
        { "│", "CmpBorder" },
        { "┘", "CmpBorder" },
        { "─", "CmpBorder" },
        { "└", "CmpBorder" },
        { "│", "CmpBorder" },
      }

      local cmp_doc_border = {
        { "┌", "CmpDocBorder" },
        { "─", "CmpDocBorder" },
        { "┐", "CmpDocBorder" },
        { "│", "CmpDocBorder" },
        { "┘", "CmpDocBorder" },
        { "─", "CmpDocBorder" },
        { "└", "CmpDocBorder" },
        { "│", "CmpDocBorder" },
      }

      local bordered = function()
        return cmp.config.window.bordered({
          border = cmp_border,
          winhighlight = "Normal:CmpPmenu,FloatBorder:CmpBorder,CursorLine:PmenuSel,Search:None",
        })
      end

      local bordered_docs = function()
        return cmp.config.window.bordered({
          border = cmp_doc_border,
          winhighlight = "Normal:CmpDoc,FloatBorder:CmpDocBorder,CursorLine:PmenuSel,Search:None",
        })
      end

      cmp.setup({
        snippet = {
          expand = function(args)
            require("luasnip").lsp_expand(args.body)
          end,
        },
        window = {
          completion = bordered(),
          documentation = bordered_docs(),
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-b>"] = cmp.mapping.scroll_docs(-4),
          ["<C-f>"] = cmp.mapping.scroll_docs(4),
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<C-e>"] = cmp.mapping.abort(),
          ["<CR>"] = cmp.mapping.confirm({ select = true }),
        }),
        sources = {
          { name = "nvim_lsp" },
        },
      })
    end,
  },
}
