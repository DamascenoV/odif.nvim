--- Thin bridge to vim._core.ui2: gives us the cmdline window/buffer
--- and a namespace for our extmarks. Never opens a floating window.

local M = {}

local NS = vim.api.nvim_create_namespace('odif')

---@class odif.ui2.Ctx
---@field buf integer
---@field win integer
---@field ns  integer
---@field ui2 table
---@field saved { height: integer, cmdheight: integer, hidden: boolean }

---@return odif.ui2.Ctx
function M.acquire()
  local ui2 = require('vim._core.ui2')
  ui2.check_targets() -- ensures bufs.cmd / wins.cmd are valid
  local cfg = vim.api.nvim_win_get_config(ui2.wins.cmd)
  return {
    buf = ui2.bufs.cmd,
    win = ui2.wins.cmd,
    ns = NS,
    ui2 = ui2,
    saved = {
      height = vim.api.nvim_win_get_height(ui2.wins.cmd),
      cmdheight = vim.o.cmdheight,
      hidden = cfg.hide or false,
    },
  }
end

--- Make sure the cmdline window is visible while the picker is active.
--- Honour the user's `cmdheight` as the lower bound so the cmdline area
--- never shrinks below what they configured.
---@param ctx odif.ui2.Ctx
---@param min_height integer
function M.ensure_visible(ctx, min_height)
  local want = math.max(min_height, ctx.saved.cmdheight, 1)
  local cfg = vim.api.nvim_win_get_config(ctx.win)
  if cfg.hide or vim.api.nvim_win_get_height(ctx.win) ~= want then
    pcall(vim.api.nvim_win_set_config, ctx.win, { hide = false, height = want })
  end
end

--- Resize the cmdline window for picker content, but never below the
--- user's configured `cmdheight`. Also bumps `vim.o.cmdheight` so
--- Neovim reserves the rows at the bottom of the screen — otherwise
--- the floating cmd window overlaps the statusline.
---@param ctx odif.ui2.Ctx
---@param desired integer
function M.set_height(ctx, desired)
  local want = math.max(desired, ctx.saved.cmdheight, 1)
  local old_height = vim.api.nvim_win_get_height(ctx.win)
  local old_cmdheight = vim.o.cmdheight
  local shrinking = old_height > want or old_cmdheight > want

  local function set_cmdheight()
    if vim.o.cmdheight ~= want then
      -- Mirror ui2's own pattern: keep cursor stable, suppress autocmds.
      vim._with({ noautocmd = true, o = { splitkeep = 'screen' } }, function() vim.o.cmdheight = want end)
    end
  end

  local function set_win_height()
    if vim.api.nvim_win_get_height(ctx.win) ~= want then
      -- The ui2 command window is configured as a special external/floating
      -- window, so update its config height directly. nvim_win_set_height()
      -- can leave the old bottom row visually stale after a shrink.
      pcall(vim.api.nvim_win_set_config, ctx.win, { hide = false, height = want })
    end
  end

  if shrinking then
    -- Release the screen row first, then resize the ui2 window into it.
    set_cmdheight()
    set_win_height()
    pcall(vim.cmd, 'redraw!')
  else
    -- Reserve rows first when growing so the command window does not
    -- briefly overlap the statusline.
    set_win_height()
    set_cmdheight()
  end
end

--- Restore the cmdline buffer/window to ui2's idle state — same height,
--- same hidden flag, same cmdheight as before the picker was opened.
---@param ctx odif.ui2.Ctx
function M.release(ctx)
  vim.api.nvim_buf_clear_namespace(ctx.buf, ctx.ns, 0, -1)
  pcall(vim.api.nvim_buf_set_lines, ctx.buf, 0, -1, false, { '' })

  -- Restore window geometry to what we found on acquire.
  pcall(vim.api.nvim_win_set_config, ctx.win, {
    hide = ctx.saved.hidden,
    height = math.max(1, ctx.saved.height),
  })

  -- Restore cmdheight (we may have grown it above the user's value to
  -- make room for the picker). Mirror ui2's noautocmd pattern.
  if vim.o.cmdheight ~= ctx.saved.cmdheight then
    vim._with({ noautocmd = true, o = { splitkeep = 'screen' } }, function() vim.o.cmdheight = ctx.saved.cmdheight end)
  end
end

return M
