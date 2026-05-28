--- Builtin source: live grep via `rg`. Each query change re-spawns rg
--- (debounced upstream) and streams matches back. Items are raw
--- "file:line:col:text" lines from `rg --vimgrep`-style output.
---
--- Differs from regular sources by setting `live = true`, which routes
--- the user's query straight to `source.refresh(query)` instead of
--- being matched locally.

local util = require('odif.util')

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
  prompt = 'Grep: ',
  live = true,

  items = function(set) set({}) end, -- start empty; refresh fills it

  refresh = function(query)
    local odif = require('odif')
    local cfg = odif.config.grep or {}
    if not query or #query < (cfg.min_query or 2) then
      odif.set_items({})
      return
    end
    if not pick_command() then return end

    local cmd = {
      'rg',
      '--column',
      '--line-number',
      '--no-heading',
      '--color=never',
      '--smart-case',
    }
    for _, glob in ipairs(util.build_globs(cfg)) do
      cmd[#cmd + 1] = '--glob'
      cmd[#cmd + 1] = glob
    end
    cmd[#cmd + 1] = '--'
    cmd[#cmd + 1] = query
    cmd[#cmd + 1] = '.'
    odif.set_items_from_cli(cmd)
  end,

  format_item = function(it)
    if type(it) == 'string' then return it end
    return it.raw
  end,

  quickfix_item = function(it)
    local m = type(it) == 'string' and parse(it) or it
    if not m or not m.file then return nil end
    return { filename = m.file, lnum = m.lnum, col = m.col, text = m.raw }
  end,

  filter_text = function(it)
    local m = type(it) == 'string' and parse(it) or it
    return (m and m.file) or ''
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
    if not m or not m.file then return end
    require('odif.preview').show(target_win, m.file, m.lnum, m.col)
  end,
}
