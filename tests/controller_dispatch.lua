-- Test the controller's key→action classifier and user-mapping overrides.
io.stdout:setvbuf('no')
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local controller = require('odif.controller')
local classify = controller._classify
local build_mappings = controller._build_mappings
assert(classify and build_mappings, 'controller did not expose test back doors')

local default = build_mappings(nil)

local function ck(ch, want)
  local got = classify(ch, default)
  assert(got == want, ('classify(%q) = %s, want %s'):format(ch, got, want))
end

ck('\27', 'abort')
ck('\3', 'abort')
ck('\r', 'choose')
ck('\n', 'choose_literal') -- <C-j>
ck('\127', 'bs')
ck('\14', 'next')
ck('\16', 'prev')
ck('\19', 'next')
ck('\18', 'prev')
ck('\10', 'choose_literal')
ck('\4', 'choose_literal')
ck('\17', 'quickfix')
ck('\15', 'glob_filter')
ck('\21', 'clear')
ck('\23', 'word_back')
ck('a', 'insert')
ck('Z', 'insert')
ck('/', 'insert')
ck(vim.api.nvim_replace_termcodes('<Left>', true, true, true), 'caret_left')
ck(vim.api.nvim_replace_termcodes('<Right>', true, true, true), 'caret_right')
ck(vim.api.nvim_replace_termcodes('<Home>', true, true, true), 'caret_home')
ck(vim.api.nvim_replace_termcodes('<End>', true, true, true), 'caret_end')
ck(vim.api.nvim_replace_termcodes('<Del>', true, true, true), 'del')
ck(vim.api.nvim_replace_termcodes('<Up>', true, true, true), 'prev')
ck(vim.api.nvim_replace_termcodes('<Down>', true, true, true), 'next')
ck('\t', 'preview_toggle')

-- User mapping overrides:
--   * add a new binding via keytrans form (^X → <C-x>)
--   * disable both forms of Tab (raw '\t' and keytrans '<Tab>')
local overridden = build_mappings({
  ['\t'] = false,
  ['<Tab>'] = false,
  ['<C-x>'] = 'choose_literal',
})
assert(classify('\t', overridden) == 'noop', 'Tab disable failed')
local cx = string.char(24) -- ^X
assert(classify(cx, overridden) == 'choose_literal', '<C-x> override failed')
-- And the default Tab binding must still exist in the unmodified map
-- (i.e. build_mappings did not mutate the shared default).
assert(classify('\t', default) == 'preview_toggle', 'default map mutated!')

print('classifier OK (overrides honoured)')
