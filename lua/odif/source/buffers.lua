--- Builtin source: list listed buffers.

return {
  name = 'buffers',
  prompt = 'Switch to buffer: ',
  items = function(set)
    local items = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted then
        local name = vim.api.nvim_buf_get_name(b)
        if name == '' then name = ('[No Name #%d]'):format(b) end
        items[#items + 1] = { bufnr = b, name = name }
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
