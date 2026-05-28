-- UI test: attach a fake UI so ui2 activates, then drive render/paint.
-- ui2.enable() bails when no UI is attached, so we monkey-patch
-- vim.api.nvim_list_uis. ui2 redirects/captures stdout, so we log to a file.

local LOG = '/tmp/odif-ui-test.log'
local f = io.open(LOG, 'w')
local function L(msg)
  f:write(msg .. '\n')
  f:flush()
end
local function bail(msg)
  L('FAIL: ' .. msg)
  io.stderr:write('FAIL: ' .. msg .. '\n')
  vim.cmd('cquit 1')
end

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.api.nvim_list_uis = function() return { { chan = 1 } } end

local odif = require('odif')
odif.setup()

local bridge = require('odif.ui2_bridge')
local ctx = bridge.acquire()
if not vim.api.nvim_buf_is_valid(ctx.buf) then bail('cmd buf invalid') end
if not vim.api.nvim_win_is_valid(ctx.win) then bail('cmd win invalid') end
L(('cmd buf=%d win=%d'):format(ctx.buf, ctx.win))

local match = require('odif.match')
local items = { 'init.lua', 'controller.lua', 'render.lua', 'match.lua' }
local hits = match.run(items, 'lua', true)
if #hits ~= 4 then bail('expected 4 hits, got ' .. #hits) end

local render = require('odif.render')
local state = {
  ctx = ctx,
  config = odif.config,
  query = 'lu',
  stritems = items,
  matches = hits,
  current_ind = 2,
  busy = false,
}
render.paint(state)

local lines = vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false)
L('line[1]=' .. vim.inspect(lines[1]))
if not lines[1]:find('odif❭', 1, true) then bail('prompt missing') end
if not lines[1]:find('lu', 1, true) then bail('query missing') end

local marks = vim.api.nvim_buf_get_extmarks(ctx.buf, ctx.ns, 0, -1, { details = true })
L('extmarks=' .. #marks)
if #marks < 2 then bail('expected ≥2 extmarks') end

local current_hl = odif.config.hl.current
local has_current, current_text = false, nil
for _, m in ipairs(marks) do
  local d = m[4]
  if d and d.hl_group == current_hl then
    has_current = true
    local row = m[2] + 1
    current_text = lines[row]:sub(m[3] + 1, d.end_col)
  end
end
if not has_current then bail('no chunk highlighted with ' .. current_hl) end
L('current chunk=' .. current_text .. ' (hl=' .. current_hl .. ')')

bridge.release(ctx)
L('UI TEST OK')

-- Also write a marker stdout users can grep on (may be lost):
io.stdout:write('UI TEST OK (see ' .. LOG .. ')\n')
f:close()
