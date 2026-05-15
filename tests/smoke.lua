-- Headless smoke test: load all modules, exercise the matcher, render path.
-- The ui2 bridge is exercised only when a UI is attached.

io.stdout:setvbuf('no')
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- 1) modules load
local ok_init, odif = pcall(require, 'odif')
assert(ok_init, 'failed to require odif: ' .. tostring(odif))
require('odif.controller')
require('odif.render')
require('odif.match')
require('odif.ui2_bridge')
require('odif.source.buffers')
require('odif.source.files')
print('all modules require OK')

-- 2) matcher correctness
local match = require('odif.match')
local items = { 'init.lua', 'controller.lua', 'render.lua', 'match.lua', 'README.md' }
local hits = match.run(items, 'lua', true)
assert(#hits == 4, '#hits should be 4, got ' .. #hits)
print('matcher hits:', vim.inspect(vim.tbl_map(function(i) return items[i] end, hits)))

-- empty query → all items in original order
local all = match.run(items, '', true)
assert(#all == #items)
for i = 1, #items do
  assert(all[i] == i)
end

-- no match
local none = match.run(items, 'zzzzz', true)
assert(#none == 0)

-- ranking: shorter window beats longer
local rank = match.run({ 'foo_bar', 'fXXXXoo_bar' }, 'fb', true)
assert(rank[1] == 1, 'foo_bar should rank first')
print('ranking OK')

-- 3) public API surface — resume/ui_select are present even without UI.
assert(type(odif.start) == 'function', 'start missing')
assert(type(odif.stop) == 'function', 'stop missing')
assert(type(odif.resume) == 'function', 'resume missing')
assert(type(odif.set_items) == 'function', 'set_items missing')
assert(type(odif.append_items) == 'function', 'append_items missing')
assert(type(odif.set_items_from_cli) == 'function', 'set_items_from_cli missing')
assert(type(odif.ui_select) == 'function', 'ui_select missing')
print('public API OK')

-- resume with no prior session must warn, not crash.
odif._last_session = nil
odif.resume()
print('resume(no prior) OK')

-- 4) only run UI/bridge tests if a UI is attached.
if #vim.api.nvim_list_uis() == 0 then
  print('SMOKE OK (headless, skipped UI tests)')
  return
end

odif.setup()
local bridge = require('odif.ui2_bridge')
local ctx = bridge.acquire()
assert(vim.api.nvim_buf_is_valid(ctx.buf), 'cmd buf invalid')
assert(vim.api.nvim_win_is_valid(ctx.win), 'cmd win invalid')
print('ui2 cmd buf=' .. ctx.buf .. ' win=' .. ctx.win)

local render = require('odif.render')
local state = {
  ctx = ctx,
  config = odif.config,
  query = 'lu',
  stritems = items,
  matches = hits,
  current_ind = 1,
  busy = false,
}
local ok_paint, err = pcall(render.paint, state)
assert(ok_paint, 'paint failed: ' .. tostring(err))
local marks = vim.api.nvim_buf_get_extmarks(ctx.buf, ctx.ns, 0, -1, { details = true })
assert(#marks >= 1, 'expected at least one extmark, got ' .. #marks)
print('paint OK, extmark count:', #marks)
bridge.release(ctx)
print('SMOKE OK (with UI)')
