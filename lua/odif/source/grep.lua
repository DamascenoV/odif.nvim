--- Builtin source: live grep via `rg`. Each query change re-spawns rg
--- (debounced upstream) and streams matches back. Items are raw
--- "file:line:col:text" lines from `rg --vimgrep`-style output.
---
--- Differs from regular sources by setting `live = true`, which routes
--- the user's query straight to `source.refresh(query)` instead of
--- being matched locally.

local function pick_command()
  if vim.fn.executable('rg') == 1 then return 'rg' end
  vim.notify('[odif] grep source needs ripgrep (`rg`)', vim.log.levels.ERROR)
end

local function parse(line)
  local file, lnum, col = line:match('^([^:]+):(%d+):(%d+):')
  if not file then return nil end
  return { file = file, lnum = tonumber(lnum), col = tonumber(col), raw = line }
end

return {
  name = 'grep',
  live = true,

  items = function(set) set({}) end, -- start empty; refresh fills it

  refresh = function(query)
    local odif = require('odif')
    if not query or #query < 2 then
      odif.set_items({})
      return
    end
    if not pick_command() then return end
    odif.set_items_from_cli({
      'rg',
      '--column',
      '--line-number',
      '--no-heading',
      '--color=never',
      '--smart-case',
      '--',
      query,
      '.',
    })
  end,

  format_item = function(it)
    if type(it) == 'string' then return it end
    return it.raw
  end,

  choose = function(it)
    local m = type(it) == 'string' and parse(it) or it
    if not m or not m.file then return end
    vim.cmd.edit(vim.fn.fnameescape(m.file))
    pcall(vim.api.nvim_win_set_cursor, 0, { m.lnum, math.max(0, m.col - 1) })
    vim.cmd('normal! zz')
  end,

  preview = function(it, target_win)
    local m = type(it) == 'string' and parse(it) or it
    if not m or not m.file or vim.fn.filereadable(m.file) ~= 1 then return end
    vim.api.nvim_win_call(target_win, function()
      vim.cmd('edit ' .. vim.fn.fnameescape(m.file))
      pcall(vim.api.nvim_win_set_cursor, 0, { m.lnum, math.max(0, m.col - 1) })
      vim.cmd('normal! zz')
    end)
  end,
}
