--- Builtin source: list files under cwd via `rg --files`, falling back
--- to `fd` then `find`. Streams stdout asynchronously into the picker
--- so the prompt is responsive even on huge repos.

local command

local function pick_command()
  if command then return command end
  if vim.fn.executable('rg') == 1 then
    command = { 'rg', '--files', '--hidden', '--glob', '!.git' }
  elseif vim.fn.executable('fd') == 1 then
    command = { 'fd', '--type', 'f', '--hidden', '--exclude', '.git' }
  else
    command = { 'find', '.', '-type', 'f', '-not', '-path', '*/.git/*' }
  end
  return command
end

return {
  name = 'files',
  prompt = 'Find file: ',
  items = function(set)
    -- Bring the picker up empty, then stream the listing in.
    set({})
    vim.schedule(function() require('odif').set_items_from_cli(pick_command()) end)
  end,
  choose = function(it)
    if it and it ~= '' then vim.cmd.edit(vim.fn.fnameescape(it)) end
  end,
  choose_literal = function(text)
    if text and text ~= '' then vim.cmd.edit(vim.fn.fnameescape(text)) end
  end,
  preview = function(it, target_win)
    if not it or it == '' then return end
    require('odif.preview').show(target_win, it, 1, 1)
  end,
}
