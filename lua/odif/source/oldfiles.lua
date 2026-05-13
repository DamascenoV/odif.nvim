--- Builtin source: recently opened files (vim.v.oldfiles), filtered to
--- those that still exist on disk. Synchronous and fast.

return {
  name = 'oldfiles',
  items = function(set)
    local cwd = vim.fn.getcwd()
    local out = {}
    for _, f in ipairs(vim.v.oldfiles or {}) do
      if f and f ~= '' and vim.fn.filereadable(f) == 1 then
        -- Show paths relative to cwd when applicable for readability.
        local display = f
        if f:sub(1, #cwd) == cwd then
          display = f:sub(#cwd + 2)
        end
        out[#out + 1] = { path = f, display = display }
      end
    end
    set(out)
  end,
  format_item = function(it) return it.display end,
  choose = function(it)
    if it and it.path then vim.cmd.edit(vim.fn.fnameescape(it.path)) end
  end,
  choose_literal = function(text)
    if text and text ~= '' then vim.cmd.edit(vim.fn.fnameescape(text)) end
  end,
}
