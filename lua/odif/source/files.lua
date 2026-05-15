--- Builtin source: list files under cwd via `rg --files`, falling back
--- to `fd` then `find`. Streams stdout asynchronously into the picker
--- so the prompt is responsive even on huge repos.

local function pick_command()
  if vim.fn.executable('rg') == 1 then
    return { 'rg', '--files', '--hidden', '--glob', '!.git' }
  elseif vim.fn.executable('fd') == 1 then
    return { 'fd', '--type', 'f', '--hidden', '--exclude', '.git' }
  else
    return { 'find', '.', '-type', 'f', '-not', '-path', '*/.git/*' }
  end
end

return {
  name = 'files',
  items = function(set)
    -- Bring the picker up empty, then stream the listing in.
    set({})
    vim.schedule(function() require('odif').set_items_from_cli(pick_command()) end)
  end,
  format_item = function(it) return it end,
  choose = function(it)
    if it and it ~= '' then vim.cmd.edit(vim.fn.fnameescape(it)) end
  end,
  choose_literal = function(text)
    if text and text ~= '' then vim.cmd.edit(vim.fn.fnameescape(text)) end
  end,
  preview = function(it, target_win)
    if not it or it == '' then return end
    if vim.fn.filereadable(it) ~= 1 then return end
    vim.api.nvim_win_call(target_win, function() vim.cmd('edit ' .. vim.fn.fnameescape(it)) end)
  end,
}
