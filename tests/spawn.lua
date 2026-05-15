-- Verify the spawn wrapper buffers and emits stdout lines correctly.
local LOG = '/tmp/odif-spawn-test.log'
local f = io.open(LOG, 'w')
local function L(msg)
  f:write(msg .. '\n')
  f:flush()
end

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local spawn = require('odif.spawn')

local seen = {}
local done = false
local exit_code

spawn.lines({ 'sh', '-c', 'printf "alpha\\nbeta\\ngamma\\n"' }, function(lines)
  for _, l in ipairs(lines) do
    seen[#seen + 1] = l
  end
end, function(code)
  exit_code = code
  done = true
end)

vim.wait(2000, function() return done end, 10)

L('done=' .. tostring(done))
L('exit=' .. tostring(exit_code))
L('lines=' .. vim.inspect(seen))

assert(done, 'process never finished')
assert(exit_code == 0, 'non-zero exit')
assert(#seen == 3, 'expected 3 lines, got ' .. #seen)
assert(seen[1] == 'alpha' and seen[2] == 'beta' and seen[3] == 'gamma', 'unexpected line content')

L('SPAWN OK')
io.stdout:write('SPAWN OK (see ' .. LOG .. ')\n')
f:close()
