--- Small shared helpers for odif internals.

local M = {}

--- Format `path` relative to `cwd` if it lives under it; otherwise return
--- the home-shortened absolute path so $HOME shows as ~.
---@param path string
---@param cwd? string
---@return string
function M.display_path(path, cwd)
  if path == '' then return path end
  cwd = cwd or vim.fn.getcwd()
  local prefix = cwd:sub(-1) == '/' and cwd or (cwd .. '/')
  if path:sub(1, #prefix) == prefix then return path:sub(#prefix + 1) end
  return vim.fn.fnamemodify(path, ':~')
end

--- Close a libuv timer/handle if it is still open.
---@param timer any|nil
function M.safe_close_timer(timer)
  if timer and not timer:is_closing() then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
  end
end

--- Build one display string for a source item.
---@param source odif.Source
---@param item any
---@return string
function M.project_one(source, item)
  if type(item) == 'string' then return item end
  local fmt = source.format_item or tostring
  return fmt(item)
end

--- Build an identity index array, 1..n.
---@param n integer
---@return integer[]
function M.make_identity(n)
  local out = {}
  for i = 1, n do
    out[i] = i
  end
  return out
end

local function listify(value)
  if value == nil or value == false then return {} end
  if type(value) == 'table' then return value end
  return { value }
end

--- Convert { glob=..., filetypes=... } into ripgrep/fd-style glob patterns.
--- `filetypes` is intentionally extension-oriented: { 'lua', 'ts' } becomes
--- { '*.lua', '*.ts' }. Use `glob` for richer patterns like `lua/**`.
---@param opts table|nil
---@return string[]
function M.build_globs(opts)
  opts = opts or {}
  local out = {}
  for _, glob in ipairs(listify(opts.glob)) do
    if type(glob) == 'string' and glob ~= '' then out[#out + 1] = glob end
  end
  for _, ft in ipairs(listify(opts.filetypes)) do
    if type(ft) == 'string' and ft ~= '' then
      ft = ft:gsub('^%.', '')
      out[#out + 1] = '*.' .. ft
    end
  end
  return out
end

---@param source odif.Source
---@param item any
---@param stritem string
---@return string
function M.filter_text(source, item, stritem)
  if source and source.filter_text then return source.filter_text(item) end
  if type(item) == 'table' then return item.filename or item.file or item.path or item.name or stritem end
  return stritem
end

---@param text string
---@param glob string|nil
---@return boolean
function M.matches_glob(text, glob)
  if not glob or glob == '' then return true end
  return vim.fn.match(text, vim.fn.glob2regpat(glob)) >= 0
end

---@param state odif.State
---@param matches integer[]
---@return integer[]
function M.apply_glob_filter(state, matches)
  local glob = state.filter_glob
  if not glob or glob == '' then return matches end
  local out = {}
  for _, idx in ipairs(matches) do
    local text = M.filter_text(state.source, state.items[idx], state.stritems[idx])
    if M.matches_glob(text, glob) then out[#out + 1] = idx end
  end
  return out
end

return M
