-- Verify each builtin source has the expected shape and produces items.
io.stdout:setvbuf('no')
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local odif = require('odif')
-- Avoid setup() so we don't try to enable ui2 in headless; just hit
-- registry construction directly.
local sources = {
  buffers = require('odif.source.buffers'),
  files = require('odif.source.files'),
  oldfiles = require('odif.source.oldfiles'),
  help = require('odif.source.help'),
  lsp_symbols = require('odif.source.lsp_symbols'),
  grep = require('odif.source.grep'),
}

-- Verify grep is correctly marked live and can parse rg output.
assert(sources.grep.live == true, 'grep should be live')
assert(type(sources.grep.refresh) == 'function', 'grep needs refresh()')
local fmt = sources.grep.format_item('foo.lua:42:7:print(x)')
assert(fmt == 'foo.lua:42:7:print(x)', 'grep.format_item identity for strings')

for name, src in pairs(sources) do
  assert(type(src) == 'table', 'source ' .. name .. ' not table')
  assert(type(src.name) == 'string', name .. ' missing name')
  assert(type(src.items) == 'function', name .. ' missing items()')
  assert(type(src.format_item or tostring) == 'function', name .. ' bad format_item')
  assert(type(src.choose) == 'function' or src.choose == nil, name .. ' bad choose')
end
print('shape OK for all 6 sources')

-- buffers: should produce at least one entry (the *scratch* buffer).
local got
sources.buffers.items(function(out) got = out end)
assert(type(got) == 'table', 'buffers.items did not call set()')
print(('buffers produced %d items'):format(#got))

-- oldfiles: may be empty in headless; just ensure no crash.
sources.oldfiles.items(function(out) got = out end)
assert(type(got) == 'table', 'oldfiles bad')
print(('oldfiles produced %d items'):format(#got))

-- help: should find at least the core help tags.
sources.help.items(function(out) got = out end)
assert(#got > 100, 'expected >100 help tags, got ' .. #got)
print(('help produced %d tags'):format(#got))

-- lsp_symbols: with no client attached, returns {} after a notify.
sources.lsp_symbols.items(function(out) got = out end)
assert(type(got) == 'table', 'lsp_symbols bad')
print('lsp_symbols handles no-client case')

print('SOURCES OK')
