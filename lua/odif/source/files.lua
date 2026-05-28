--- Builtin source: list files under cwd via `rg --files`, falling back
--- to `fd` then `find`. Streams stdout asynchronously into the picker
--- so the prompt is responsive even on huge repos.

local util = require('odif.util')

local function append_globs(cmd, globs, flag)
  for _, glob in ipairs(globs) do
    cmd[#cmd + 1] = flag
    cmd[#cmd + 1] = glob
  end
end

local function pick_command()
  local globs = util.build_globs(require('odif').config.files)
  local cmd
  if vim.fn.executable('rg') == 1 then
    cmd = { 'rg', '--files', '--hidden', '--glob', '!.git' }
    append_globs(cmd, globs, '--glob')
  elseif vim.fn.executable('fd') == 1 then
    cmd = { 'fd', '--type', 'f', '--hidden', '--exclude', '.git' }
    for _, glob in ipairs(globs) do
      cmd[#cmd + 1] = '--glob'
      cmd[#cmd + 1] = glob
    end
  else
    cmd = { 'find', '.', '-type', 'f', '-not', '-path', '*/.git/*' }
    if #globs > 0 then
      cmd[#cmd + 1] = '('
      for i, glob in ipairs(globs) do
        if i > 1 then cmd[#cmd + 1] = '-o' end
        cmd[#cmd + 1] = '-name'
        cmd[#cmd + 1] = glob
      end
      cmd[#cmd + 1] = ')'
    end
  end
  return cmd
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
  quickfix_item = function(it)
    if it and it ~= '' then return { filename = it, lnum = 1, col = 1, text = it } end
  end,
  preview = function(it, target_win)
    if not it or it == '' then return end
    require('odif.preview').show(target_win, it, 1, 1)
  end,
}
