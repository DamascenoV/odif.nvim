-- Test the controller's key→action classifier directly (no input loop).
io.stdout:setvbuf('no')
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local controller = require('odif.controller')
-- classify is local; expose via a tiny back door: patch _G.
-- Instead, re-load the file to reach the local: not possible.
-- We just hit the real entry points by feeding to a fake state.
-- Easier: re-implement the call surface by re-evaluating only classify.
local src = io.open('lua/odif/controller.lua'):read('*a')
local cls_src = src:match('local function classify%b()[^\n]*\n(.-)\nend\n')
assert(cls_src, 'could not extract classify')
-- Build a tiny function with the same body.
local fn = assert(loadstring('local vim = vim\nreturn function(ch)\n' .. cls_src .. '\nend'))()
local classify = fn

local cases = {
  { '\27', 'abort' },
  { '\3', 'abort' },
  { '\r', 'choose' },
  { '\n', 'choose_literal' }, -- \n == <C-j>, fido literal
  { '\127', 'bs' },
  { '\14', 'next' },
  { '\16', 'prev' },
  { '\19', 'next' },
  { '\18', 'prev' },
  { '\10', 'choose_literal' },
  { '\4', 'choose_literal' },
  { '\21', 'clear' },
  { '\23', 'word_back' },
  { 'a', 'insert' },
  { 'Z', 'insert' },
  { '/', 'insert' },
  { vim.api.nvim_replace_termcodes('<Left>', true, true, true), 'caret_left' },
  { vim.api.nvim_replace_termcodes('<Right>', true, true, true), 'caret_right' },
  { vim.api.nvim_replace_termcodes('<Home>', true, true, true), 'caret_home' },
  { vim.api.nvim_replace_termcodes('<End>', true, true, true), 'caret_end' },
  { vim.api.nvim_replace_termcodes('<Del>', true, true, true), 'del' },
  { vim.api.nvim_replace_termcodes('<Up>', true, true, true), 'prev' },
  { vim.api.nvim_replace_termcodes('<Down>', true, true, true), 'next' },
  { '\t', 'preview_toggle' },
}
for _, c in ipairs(cases) do
  local ch, want = c[1], c[2]
  local got = classify(ch)
  assert(got == want, ('classify(%q) = %s, want %s'):format(ch, got, want))
end
print('classifier OK (' .. #cases .. ' cases)')
