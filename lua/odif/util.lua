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

return M
