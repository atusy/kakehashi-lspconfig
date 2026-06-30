-- Convert nvim-lspconfig lsp/*.lua configs into kakehashi *.toml configs.
--
-- Usage:
--   NVIM_LSPCONFIG=/path/to/nvim-lspconfig nvim --headless -l scripts/convert.lua
--
-- SRC defaults to a sibling `nvim-lspconfig` checkout; OUT is this repo's
-- `lsp/` directory (resolved from this script's location).
--
-- Evaluates each config with the real `vim` API (so vim.fn.has, vim.list_extend,
-- vim.env, etc. resolve correctly), then serializes the resulting table to TOML.
--
-- Note: rootMarkers KEEP `.git`. A server that sets its own rootMarkers
-- replaces kakehashi's `[".git"]` default outright (override, not merge), so
-- `.git` must be listed explicitly or it is dismissed as a marker entirely.

local script_path = debug.getinfo(1, 'S').source:sub(2)
local repo_root = vim.fn.fnamemodify(script_path, ':p:h:h')
local nvim_lspconfig = vim.env.NVIM_LSPCONFIG
  or (vim.fn.fnamemodify(repo_root, ':h') .. '/nvim-lspconfig')
local SRC = nvim_lspconfig .. '/lsp'
local OUT = repo_root .. '/lsp'

vim.fn.mkdir(OUT, 'p')

-- Some configs `require('lspconfig.util')` (or 'lspconfig') for root-dir
-- helpers. Stub them with an auto-stubbing proxy: any access/call yields
-- another proxy, so `util.root_pattern('go.mod')` etc. evaluate without error.
-- The resulting root_dir value is non-convertible and gets a WARN anyway.
local function make_stub()
  local stub = {}
  return setmetatable(stub, {
    __index = function()
      return make_stub()
    end,
    __call = function()
      return make_stub()
    end,
  })
end
for _, mod in ipairs({ 'lspconfig', 'lspconfig.util', 'lspconfig.configs', 'lspconfig.async' }) do
  package.preload[mod] = function()
    return make_stub()
  end
end

-- A few configs are deprecated renames that extend a sibling config via
-- `vim.tbl_extend('force', vim.lsp.config.<base>, {...})`. Resolve such
-- lookups by loading the base config so the alias inherits its real settings.
do
  local cfg_cache = {}
  vim.lsp = vim.lsp or {}
  vim.lsp.config = setmetatable({}, {
    __index = function(_, key)
      if cfg_cache[key] == nil then
        local ok, c = pcall(dofile, SRC .. '/' .. key .. '.lua')
        cfg_cache[key] = (ok and type(c) == 'table') and c or {}
      end
      return cfg_cache[key]
    end,
    __call = function() end,
  })
end

-- ---------------------------------------------------------------------------
-- TOML value serialization
-- ---------------------------------------------------------------------------

local function esc_string(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  return '"' .. s .. '"'
end

local function quote_key(k)
  if type(k) == 'string' and k:match('^[%w_%-]+$') then
    return k
  end
  return esc_string(tostring(k))
end

-- A Lua table is a "list" if its only keys are 1..#t.
local function is_list(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n == #t
end

-- Serialize an arbitrary Lua value to an inline TOML value.
-- `warns` collects "<path>: reason" strings for values that cannot be
-- represented (functions, userdata, ...). Returns nil when the value itself
-- is unrepresentable (caller should skip the key).
local function serialize(value, path, warns)
  local t = type(value)
  if t == 'string' then
    return esc_string(value)
  elseif t == 'number' then
    -- integers without trailing .0
    if value == math.floor(value) and value == value and value ~= math.huge and value ~= -math.huge then
      return string.format('%d', value)
    end
    return tostring(value)
  elseif t == 'boolean' then
    return tostring(value)
  elseif t == 'table' then
    if next(value) == nil then
      -- Empty table: in these configs an empty `{}` is an object, not a list.
      return '{}'
    end
    if is_list(value) then
      local parts = {}
      for i, v in ipairs(value) do
        local s = serialize(v, path .. '[' .. i .. ']', warns)
        if s ~= nil then
          parts[#parts + 1] = s
        end
      end
      if #parts == 0 then
        return '[]'
      end
      return '[' .. table.concat(parts, ', ') .. ']'
    else
      -- map -> inline table
      local keys = {}
      for k in pairs(value) do
        keys[#keys + 1] = k
      end
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      local parts = {}
      for _, k in ipairs(keys) do
        local v = value[k]
        local kp = path .. '.' .. tostring(k)
        if type(v) == 'function' then
          warns[#warns + 1] = kp .. ' was a Lua function and was omitted'
        else
          local s = serialize(v, kp, warns)
          if s ~= nil then
            parts[#parts + 1] = quote_key(k) .. ' = ' .. s
          else
            warns[#warns + 1] = kp .. ' (' .. type(v) .. ') could not be represented and was omitted'
          end
        end
      end
      if #parts == 0 then
        return '{}'
      end
      return '{ ' .. table.concat(parts, ', ') .. ' }'
    end
  else
    return nil -- function / userdata / thread
  end
end

-- ---------------------------------------------------------------------------
-- rootMarkers: preserve every entry (including `.git`), collapse 1-element
-- groups to a bare string. `.git` MUST be kept: a server that sets its own
-- rootMarkers replaces kakehashi's `[".git"]` default outright, so dropping
-- `.git` here would dismiss it as a marker entirely.
-- ---------------------------------------------------------------------------

local function serialize_root_markers(rm)
  -- rm is a Lua list whose elements are either strings or string-lists (groups).
  local out_entries = {}
  for _, entry in ipairs(rm) do
    if type(entry) == 'table' then
      if #entry == 1 then
        out_entries[#out_entries + 1] = esc_string(entry[1])
      elseif #entry > 1 then
        local q = {}
        for _, name in ipairs(entry) do
          q[#q + 1] = esc_string(name)
        end
        out_entries[#out_entries + 1] = '[' .. table.concat(q, ', ') .. ']'
      end
      -- empty group -> drop
    elseif type(entry) == 'string' then
      out_entries[#out_entries + 1] = esc_string(entry)
    end
  end
  return out_entries -- list of already-serialized TOML fragments
end

-- ---------------------------------------------------------------------------
-- Field classification for top-level keys we explicitly drop with a reason.
-- ---------------------------------------------------------------------------

local DROP_REASON = {
  capabilities = 'capabilities was dropped; kakehashi negotiates client capabilities itself',
  on_attach = 'on_attach (editor-side hook) was dropped; not applicable to kakehashi',
  on_init = 'on_init (editor-side hook) was dropped; not applicable to kakehashi',
  on_exit = 'on_exit (editor-side hook) was dropped; not applicable to kakehashi',
  before_init = 'before_init (editor-side hook) was dropped; not applicable to kakehashi',
  on_new_config = 'on_new_config (editor-side hook) was dropped; not applicable to kakehashi',
  get_language_id = 'get_language_id (Lua function) was dropped',
  handlers = 'handlers (client-side LSP handlers) were dropped',
  commands = 'commands (client-side user commands) were dropped',
  cmd_env = 'cmd_env was dropped; kakehashi has no per-server environment option',
  cmd_cwd = 'cmd_cwd was dropped; kakehashi has no per-server cwd option',
  single_file_support = 'single_file_support was dropped; not applicable to kakehashi',
  workspace_required = 'workspace_required was dropped; not applicable to kakehashi',
  offset_encoding = 'offset_encoding was dropped; kakehashi manages offset encoding',
  reuse_client = 'reuse_client was dropped; not applicable to kakehashi',
}
-- Keys we silently ignore (informational / handled elsewhere).
local IGNORE = { name = true, filetypes = true, cmd = true, root_markers = true,
                 root_dir = true, settings = true, init_options = true }

-- ---------------------------------------------------------------------------
-- Convert one config table to a TOML document string.
-- ---------------------------------------------------------------------------

local function convert(name, cfg)
  local warns = {}
  local body = {}

  -- cmd (build the string array directly so an empty cmd -> WARN, not `{}`)
  if type(cfg.cmd) == 'table' then
    local parts = {}
    for _, v in ipairs(cfg.cmd) do
      if type(v) == 'string' then
        parts[#parts + 1] = esc_string(v)
      end
    end
    if #parts > 0 then
      body[#body + 1] = 'cmd = [' .. table.concat(parts, ', ') .. ']'
    else
      warns[#warns + 1] = 'cmd was empty in source; set `cmd` manually or kakehashi will skip this server'
    end
  elseif type(cfg.cmd) == 'function' then
    warns[#warns + 1] = 'cmd was a Lua function (dynamic command resolution); set `cmd` manually or kakehashi will skip this server'
  else
    warns[#warns + 1] = 'no `cmd` in source; set `cmd` manually or kakehashi will skip this server'
  end

  -- languages (from filetypes, deduped)
  if cfg.filetypes ~= nil and type(cfg.filetypes) == 'table' then
    local seen, langs = {}, {}
    for _, ft in ipairs(cfg.filetypes) do
      if type(ft) == 'string' and not seen[ft] then
        seen[ft] = true
        langs[#langs + 1] = esc_string(ft)
      end
    end
    if #langs > 0 then
      body[#body + 1] = 'languages = [' .. table.concat(langs, ', ') .. ']'
    end
    if #langs == 0 then
      warns[#warns + 1] = 'filetypes was empty in source; set `languages` manually or this server never matches'
    end
  elseif type(cfg.filetypes) == 'function' then
    warns[#warns + 1] = 'filetypes was a Lua function; set `languages` manually or this server never matches'
  else
    warns[#warns + 1] = 'no `filetypes` in source; set `languages` manually or this server never matches'
  end

  -- rootMarkers (from root_markers; .git stripped). root_dir function -> warn.
  if cfg.root_markers ~= nil and type(cfg.root_markers) == 'table' then
    local entries = serialize_root_markers(cfg.root_markers)
    if #entries > 0 then
      body[#body + 1] = 'rootMarkers = [' .. table.concat(entries, ', ') .. ']'
    end
  end
  if cfg.root_dir ~= nil then
    warns[#warns + 1] = 'root_dir was a dynamic Lua function (dynamic root detection); approximate with `rootMarkers` if the default (client root) is wrong'
  end

  -- initializationOptions (from nvim `init_options`; consumed once at
  -- `initialize`) and settings (from nvim `settings`; propagated to the
  -- downstream server over workspace/didChangeConfiguration + answered on
  -- workspace/configuration). The two map to distinct kakehashi fields,
  -- matching their LSP roles, so they are kept separate.
  if type(cfg.init_options) == 'table' then
    local s = serialize(cfg.init_options, 'initializationOptions', warns)
    if s ~= nil and s ~= '{}' then
      body[#body + 1] = 'initializationOptions = ' .. s
    end
  elseif type(cfg.init_options) == 'function' then
    warns[#warns + 1] = 'init_options was a Lua function and was omitted'
  end
  if type(cfg.settings) == 'table' then
    local s = serialize(cfg.settings, 'settings', warns)
    if s ~= nil and s ~= '{}' then
      body[#body + 1] = 'settings = ' .. s
    end
  elseif type(cfg.settings) == 'function' then
    warns[#warns + 1] = 'settings was a Lua function and was omitted'
  end

  -- Remaining top-level keys: known drops + generic fallback.
  local extra_keys = {}
  for k in pairs(cfg) do
    if not IGNORE[k] then
      extra_keys[#extra_keys + 1] = k
    end
  end
  table.sort(extra_keys)
  for _, k in ipairs(extra_keys) do
    if DROP_REASON[k] then
      warns[#warns + 1] = DROP_REASON[k]
    else
      warns[#warns + 1] = string.format('unhandled field `%s` (%s) was dropped', k, type(cfg[k]))
    end
  end

  -- Assemble document.
  local lines = {}
  for _, w in ipairs(warns) do
    lines[#lines + 1] = '# WARN: ' .. w
  end
  lines[#lines + 1] = '[languageServers.' .. quote_key(name) .. ']'
  for _, b in ipairs(body) do
    lines[#lines + 1] = b
  end
  return table.concat(lines, '\n') .. '\n', warns
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------

local files = vim.fn.globpath(SRC, '*.lua', false, true)
table.sort(files)

local ok_count, fail_count = 0, 0
local failures = {}
local with_warns = {}

for _, file in ipairs(files) do
  local name = vim.fn.fnamemodify(file, ':t:r')
  local ok, cfg = pcall(dofile, file)
  local out_path = OUT .. '/' .. name .. '.toml'
  if ok and type(cfg) == 'table' then
    local doc, warns = convert(name, cfg)
    local fh = io.open(out_path, 'w')
    fh:write(doc)
    fh:close()
    ok_count = ok_count + 1
    if #warns > 0 then
      with_warns[#with_warns + 1] = name .. ' (' .. #warns .. ')'
    end
  else
    fail_count = fail_count + 1
    failures[#failures + 1] = name .. ': ' .. tostring(cfg)
    local fh = io.open(out_path, 'w')
    fh:write('# WARN: failed to evaluate source config: ' .. tostring(cfg):gsub('\n', ' ') .. '\n')
    fh:write('# WARN: fill in cmd / languages / rootMarkers / initializationOptions manually\n')
    fh:write('[languageServers.' .. quote_key(name) .. ']\n')
    fh:close()
  end
end

local report = {}
report[#report + 1] = string.format('converted=%d failed=%d total=%d', ok_count, fail_count, #files)
report[#report + 1] = 'files_with_warnings=' .. #with_warns
if #failures > 0 then
  report[#report + 1] = '--- FAILURES ---'
  for _, f in ipairs(failures) do
    report[#report + 1] = f
  end
end
print(table.concat(report, '\n'))
