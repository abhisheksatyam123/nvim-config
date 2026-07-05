--- text-analyzer/filter.lua
--- Filter data model and matching logic.

local Filter = {}
Filter.__index = Filter

-- Available colors for filter highlighting
Filter.COLORS = {
  "Red", "Yellow", "Green", "Blue", "Purple", "Cyan", "Orange", "Grey",
}

-- Default highlight definitions (guifg + subtle guibg)
Filter.HIGHLIGHT_DEFS = {
  Red    = { guifg = "#ff6188", guibg = "#ff618820", ctermfg = "red",    ctermbg = "darkred" },
  Yellow = { guifg = "#ffd866", guibg = "#ffd86620", ctermfg = "yellow", ctermbg = "darkyellow" },
  Green  = { guifg = "#a9dc76", guibg = "#a9dc7620", ctermfg = "green",  ctermbg = "darkgreen" },
  Blue   = { guifg = "#78dce8", guibg = "#78dce820", ctermfg = "blue",   ctermbg = "darkblue" },
  Purple = { guifg = "#ab9df2", guibg = "#ab9df220", ctermfg = "magenta", ctermbg = "darkmagenta" },
  Cyan   = { guifg = "#56b6c2", guibg = "#56b6c220", ctermfg = "cyan",   ctermbg = "darkcyan" },
  Orange = { guifg = "#f69c5e", guibg = "#f69c5e20", ctermfg = "brown",  ctermbg = "brown" },
  Grey   = { guifg = "#888888", guibg = "#88888820", ctermfg = "grey",   ctermbg = "grey" },
}

-- Track which highlight groups have been defined (once per session)
local _highlights_setup = false

--- Create a new Filter object.
function Filter.new(opts)
  opts = opts or {}
  local self = setmetatable({
    name = opts.name or "Unnamed",
    pattern = opts.pattern or "",
    type = opts.type or "regex",
    color = opts.color or "Red",
    enabled = opts.enabled ~= false,
    case_sensitive = opts.case_sensitive or false,
    invert = opts.invert or false,
    priority = opts.priority or 0,
  }, Filter)
  self:_compile()
  return self
end

--- Serialize filter to a plain table (for save/load).
function Filter:to_table()
  return {
    name = self.name,
    pattern = self.pattern,
    type = self.type,
    color = self.color,
    enabled = self.enabled,
    case_sensitive = self.case_sensitive,
    invert = self.invert,
    priority = self.priority,
  }
end

--- Create from plain table.
function Filter.from_table(t)
  return Filter.new(t)
end

--- Compile the pattern into a matching function.
function Filter:_compile()
  if not self.pattern or self.pattern == "" then
    self._match_fn = function() return false end
    return
  end

  if self.type == "literal" then
    if self.case_sensitive then
      self._match_fn = function(line)
        return line:find(self.pattern, 1, true) ~= nil
      end
    else
      local lower = self.pattern:lower()
      self._match_fn = function(line)
        return line:lower():find(lower, 1, true) ~= nil
      end
    end
  else -- regex
    local flags = self.case_sensitive and "" or "i"
    local pattern = self.pattern
    if not self.case_sensitive then
      pattern = "\\c" .. pattern
    end
    local ok, regex = pcall(function()
      return vim.regex(pattern)
    end)
    if ok and regex then
      self._match_fn = function(line)
        return regex:match_str(line) ~= nil
      end
    else
      -- Fallback
      local lower = self.pattern:lower()
      if self.case_sensitive then
        self._match_fn = function(line)
          return line:find(self.pattern) ~= nil
        end
      else
        self._match_fn = function(line)
          return line:lower():find(lower, 1, true) ~= nil
        end
      end
    end
  end
end

--- Check if a line matches this filter.
function Filter:matches(line)
  return self._match_fn(line)
end

--- Check if line matches, accounting for invert.
function Filter:is_visible(line)
  local matched = self._match_fn(line)
  if self.invert then
    return not matched
  end
  return matched
end

--- Set a new pattern and recompile.
function Filter:set_pattern(new_pattern)
  self.pattern = new_pattern
  self:_compile()
end

--- Get the highlight group name for this filter's color.
function Filter:hl_group()
  return "TA_" .. self.color
end

--- Setup all highlight groups (called once globally).
function Filter.setup_highlights()
  if _highlights_setup then return end
  _highlights_setup = true

  for color, defs in pairs(Filter.HIGHLIGHT_DEFS) do
    local hl_name = "TA_" .. color
    local parts = {}
    if defs.guifg then table.insert(parts, "guifg=" .. defs.guifg) end
    if defs.guibg then table.insert(parts, "guibg=" .. defs.guibg) end
    if defs.ctermfg then table.insert(parts, "ctermfg=" .. defs.ctermfg) end
    if defs.ctermbg then table.insert(parts, "ctermbg=" .. defs.ctermbg) end
    vim.cmd("highlight default " .. hl_name .. " " .. table.concat(parts, " "))
  end
end

return Filter
