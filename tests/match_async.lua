-- Verify match.run_async chunks correctly and respects is_stale().
io.stdout:setvbuf('no')
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local match = require('odif.match')

-- Build 25k items, query that hits half of them.
local items = {}
for i = 1, 25000 do
  items[i] = (i % 2 == 0) and ('foo_bar_' .. i) or ('quux_' .. i)
end

-- 1) Successful run completes asynchronously.
local got
match.run_async(items, 'fb', true,
  { chunk_size = 4000 },
  function(matches) got = matches end)
assert(got == nil, 'on_done called synchronously?')
local ok = vim.wait(2000, function() return got ~= nil end, 5)
assert(ok and got, 'async match never finished')
assert(#got == 12500, ('expected 12500 hits, got %d'):format(#got))
print('chunked match OK (' .. #got .. ' hits)')

-- 2) Stale aborts: is_stale() returns true → on_done NOT called.
local stale_called
local stale = true
match.run_async(items, 'fb', true,
  { chunk_size = 1000, is_stale = function() return stale end },
  function() stale_called = true end)
vim.wait(300, function() return stale_called ~= nil end, 5)
assert(not stale_called, 'stale match still invoked on_done')
print('stale abort OK')

-- 3) Cancel: ticket.cancel() prevents on_done.
local cancelled_called
local t = match.run_async(items, 'fb', true,
  { chunk_size = 1000 },
  function() cancelled_called = true end)
t.cancel()
vim.wait(300, function() return cancelled_called ~= nil end, 5)
assert(not cancelled_called, 'cancelled match still invoked on_done')
print('cancel OK')

-- 4) Empty query → identity, asynchronously.
local ident
match.run_async({ 'a', 'b', 'c' }, '', true, {}, function(m) ident = m end)
vim.wait(200, function() return ident ~= nil end, 5)
assert(ident and #ident == 3 and ident[1] == 1 and ident[3] == 3,
  'empty query path broken')
print('empty query OK')

print('MATCH_ASYNC OK')
