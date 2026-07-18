--- typist/store.lua
--- SQLite persistence for learned words, mistakes, and sessions.

local Store = {}

local _db = nil
local _db_path = nil

local function now_iso()
  return os.date("%Y-%m-%dT%H:%M:%S")
end

function Store.setup(db_path)
  _db_path = db_path or (vim.fn.stdpath("data") .. "/typist.db")
end

function Store.db_path()
  return _db_path or (vim.fn.stdpath("data") .. "/typist.db")
end

function Store.init()
  if _db then return _db end

  local ok, sqlite = pcall(require, "sqlite")
  if not ok then
    vim.notify("Typist: sqlite.lua not available", vim.log.levels.WARN)
    return nil
  end

  local path = Store.db_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  local ok_new, db = pcall(sqlite.new, path, { keep_open = true })
  if not ok_new then
    vim.notify("Typist: sqlite " .. tostring(db), vim.log.levels.ERROR)
    return nil
  end
  _db = db

  _db:eval([[
    CREATE TABLE IF NOT EXISTS words (
      word TEXT PRIMARY KEY,
      count INTEGER NOT NULL DEFAULT 1,
      last_used TEXT,
      source TEXT
    )
  ]])
  _db:eval([[
    CREATE TABLE IF NOT EXISTS mistakes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      wrong TEXT NOT NULL UNIQUE,
      right TEXT,
      count INTEGER NOT NULL DEFAULT 1,
      last_seen TEXT,
      ft TEXT,
      ignored INTEGER NOT NULL DEFAULT 0
    )
  ]])
  _db:eval([[
    CREATE TABLE IF NOT EXISTS sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      started_at TEXT,
      ended_at TEXT,
      wpm_avg REAL,
      words_typed INTEGER
    )
  ]])
  pcall(function()
    _db:eval("CREATE INDEX IF NOT EXISTS idx_words_count ON words(count DESC)")
  end)
  pcall(function()
    _db:eval("CREATE INDEX IF NOT EXISTS idx_mistakes_count ON mistakes(count DESC)")
  end)

  return _db
end

function Store.close()
  if _db then
    pcall(function() _db:close() end)
    _db = nil
  end
end

--- Upsert a learned word. boost multiplies the count increment (corrections).
function Store.upsert_word(word, source, boost)
  if not word or word == "" then return end
  local db = Store.init()
  if not db then return end

  word = word:lower()
  source = source or "typed"
  boost = boost or 1
  local ts = now_iso()

  local existing = db:select("words", { where = { word = word } })
  if existing and #existing > 0 then
    local row = existing[1]
    db:update("words", {
      where = { word = word },
      set = {
        count = (row.count or 0) + boost,
        last_used = ts,
        source = source,
      },
    })
  else
    db:insert("words", {
      word = word,
      count = boost,
      last_used = ts,
      source = source,
    })
  end
end

function Store.upsert_mistake(wrong, ft)
  if not wrong or wrong == "" then return end
  local db = Store.init()
  if not db then return end

  wrong = wrong:lower()
  local ts = now_iso()

  local existing = db:select("mistakes", { where = { wrong = wrong } })
  if existing and #existing > 0 then
    local row = existing[1]
    if row.ignored and row.ignored ~= 0 then
      return -- user ignored this misspelling
    end
    db:update("mistakes", {
      where = { wrong = wrong },
      set = {
        count = (row.count or 0) + 1,
        last_seen = ts,
        ft = ft or row.ft,
      },
    })
  else
    db:insert("mistakes", {
      wrong = wrong,
      right = nil,
      count = 1,
      last_seen = ts,
      ft = ft,
      ignored = 0,
    })
  end
end

--- Record a correction: wrong → right.
function Store.record_correction(wrong, right, ft)
  if not wrong or not right or wrong == "" or right == "" then return end
  local db = Store.init()
  if not db then return end

  wrong = wrong:lower()
  right = right:lower()
  local ts = now_iso()

  local existing = db:select("mistakes", { where = { wrong = wrong } })
  if existing and #existing > 0 then
    db:update("mistakes", {
      where = { wrong = wrong },
      set = {
        right = right,
        last_seen = ts,
        ft = ft or existing[1].ft,
        count = (existing[1].count or 0) + 1,
      },
    })
  else
    db:insert("mistakes", {
      wrong = wrong,
      right = right,
      count = 1,
      last_seen = ts,
      ft = ft,
      ignored = 0,
    })
  end

  Store.upsert_word(right, "corrected", 3)
end

function Store.ignore_mistake(wrong)
  if not wrong or wrong == "" then return end
  local db = Store.init()
  if not db then return end
  wrong = wrong:lower()

  local existing = db:select("mistakes", { where = { wrong = wrong } })
  if existing and #existing > 0 then
    db:update("mistakes", {
      where = { wrong = wrong },
      set = { ignored = 1 },
    })
  else
    db:insert("mistakes", {
      wrong = wrong,
      count = 0,
      last_seen = now_iso(),
      ignored = 1,
    })
  end
end

function Store.is_ignored(wrong)
  if not wrong or wrong == "" then return false end
  local db = Store.init()
  if not db then return false end
  local rows = db:select("mistakes", { where = { wrong = wrong:lower() } })
  return rows and #rows > 0 and rows[1].ignored and rows[1].ignored ~= 0
end

--- Prefix search for cmp. Returns { {word, count}, ... }
function Store.prefix_query(prefix, limit)
  local db = Store.init()
  if not db then return {} end

  prefix = (prefix or ""):lower()
  limit = limit or 20

  local rows
  if prefix == "" then
    rows = db:eval(
      "SELECT word, count FROM words ORDER BY count DESC, last_used DESC LIMIT :lim",
      { lim = limit }
    )
  else
    rows = db:eval(
      "SELECT word, count FROM words WHERE word LIKE :p ORDER BY count DESC, last_used DESC LIMIT :lim",
      { p = prefix .. "%", lim = limit }
    )
  end

  if type(rows) ~= "table" then return {} end
  local out = {}
  for _, r in ipairs(rows) do
    if r.word then
      table.insert(out, { word = r.word, count = r.count or 0 })
    end
  end
  return out
end

function Store.top_words(n)
  return Store.prefix_query("", n or 10)
end

function Store.top_mistakes(n)
  local db = Store.init()
  if not db then return {} end
  n = n or 10
  local rows = db:eval(
    "SELECT wrong, right, count FROM mistakes WHERE ignored = 0 ORDER BY count DESC LIMIT :lim",
    { lim = n }
  )
  if type(rows) ~= "table" then return {} end
  local out = {}
  for _, r in ipairs(rows) do
    if r.wrong then
      table.insert(out, {
        wrong = r.wrong,
        right = r.right,
        count = r.count or 0,
      })
    end
  end
  return out
end

function Store.start_session()
  local db = Store.init()
  if not db then return nil end
  local started = now_iso()
  db:insert("sessions", {
    started_at = started,
    ended_at = nil,
    wpm_avg = 0,
    words_typed = 0,
  })
  local rows = db:eval("SELECT last_insert_rowid() AS id")
  if type(rows) == "table" and rows[1] and rows[1].id then
    return rows[1].id
  end
  return nil
end

function Store.end_session(session_id, wpm_avg, words_typed)
  if not session_id then return end
  local db = Store.init()
  if not db then return end
  db:update("sessions", {
    where = { id = session_id },
    set = {
      ended_at = now_iso(),
      wpm_avg = wpm_avg or 0,
      words_typed = words_typed or 0,
    },
  })
end

function Store.recent_session_wpm(n)
  local db = Store.init()
  if not db then return {} end
  n = n or 5
  local rows = db:eval(
    "SELECT wpm_avg, words_typed, started_at FROM sessions WHERE ended_at IS NOT NULL ORDER BY id DESC LIMIT :lim",
    { lim = n }
  )
  if type(rows) ~= "table" then return {} end
  return rows
end

return Store
