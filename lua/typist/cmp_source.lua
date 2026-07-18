--- typist/cmp_source.lua
--- nvim-cmp source over learned words.

local Store = require("typist.store")

local source = {}
source.__index = source

function source.new(opts)
  return setmetatable({
    max_items = (opts and opts.max_items) or 20,
  }, source)
end

function source:is_available()
  return true
end

function source:get_debug_name()
  return "typist"
end

function source:get_keyword_pattern()
  return [[\k\+]]
end

function source:complete(params, callback)
  local ok_cmp, cmp = pcall(require, "cmp")
  if not ok_cmp then
    callback({})
    return
  end

  local input = ""
  if params and params.context and params.context.cursor_before_line then
    input = params.context.cursor_before_line:match("[%a']+$") or ""
  end

  local rows = Store.prefix_query(input:lower(), self.max_items)
  local items = {}
  for _, r in ipairs(rows) do
    table.insert(items, {
      label = r.word,
      kind = cmp.lsp.CompletionItemKind.Text,
      detail = string.format("typist · %d×", r.count or 0),
      sortText = string.format("%08d", 1000000 - (r.count or 0)),
    })
  end
  callback(items)
end

--- Register with nvim-cmp if available. Also appends to global sources when possible.
function source.register(opts)
  local ok, cmp = pcall(require, "cmp")
  if not ok then
    vim.notify("Typist: nvim-cmp not found; tracking still works", vim.log.levels.DEBUG)
    return false
  end
  cmp.register_source("typist", source.new(opts))

  -- Best-effort: ensure typist is in the default source list
  pcall(function()
    local cfg = cmp.get_config()
    local sources = vim.deepcopy(cfg.sources or {})
    local has = false
    for _, s in ipairs(sources) do
      if s.name == "typist" then
        has = true
        break
      end
      -- nested group form: { { name = ... }, ... }
      if s[1] and type(s[1]) == "table" then
        for _, inner in ipairs(s) do
          if inner.name == "typist" then
            has = true
            break
          end
        end
      end
    end
    if not has then
      -- Prefer as a secondary group so LSP stays primary
      table.insert(sources, { { name = "typist" } })
      cmp.setup({ sources = sources })
    end
  end)

  return true
end

return source
