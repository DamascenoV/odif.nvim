--- Builtin source: list listed buffers.

--- Format `path` relative to `cwd` if it lives under it; otherwise return
--- the home-shortened absolute path so $HOME shows as ~.
local function display_path(path, cwd)
  if path == '' then return path end
  local prefix = cwd:sub(-1) == '/' and cwd or (cwd .. '/')
  if path:sub(1, #prefix) == prefix then return path:sub(#prefix + 1) end
  return vim.fn.fnamemodify(path, ':~')
end

return {
  name = 'buffers',
  prompt = 'Switch to buffer: ',
  items = function(set)
    local cwd = vim.fn.getcwd()
    local items = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted then
        local full = vim.api.nvim_buf_get_name(b)
        local display = full == '' and ('[No Name #%d]'):format(b) or display_path(full, cwd)
        items[#items + 1] = { bufnr = b, name = display, path = full }
      end
    end
    set(items)
  end,
  format_item = function(it) return it.name end,
  choose = function(it)
    if it and it.bufnr and vim.api.nvim_buf_is_valid(it.bufnr) then vim.api.nvim_set_current_buf(it.bufnr) end
  end,
  preview = function(it, target_win)
    if it and it.bufnr and vim.api.nvim_buf_is_valid(it.bufnr) then
      pcall(vim.api.nvim_win_set_buf, target_win, it.bufnr)
    end
  end,
}
