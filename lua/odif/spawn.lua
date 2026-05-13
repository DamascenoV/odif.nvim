--- Tiny line-buffered subprocess wrapper used by streaming sources.
--- Returns a handle with `:kill()`. All callbacks are wrapped in
--- `vim.schedule` so they run on the main loop and may touch the API.

local M = {}
local uv = vim.uv or vim.loop

---@param cmd string[]                     argv
---@param on_lines fun(lines: string[])    called with each batch
---@param on_exit  fun(code: integer)      called once when the process ends
---@return { kill: fun() }
function M.lines(cmd, on_lines, on_exit)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local pending = ''
  local handle

  handle = uv.spawn(cmd[1], {
    args  = vim.list_slice(cmd, 2),
    stdio = { nil, stdout, stderr },
  }, function(code)
    if stdout and not stdout:is_closing() then stdout:close() end
    if stderr and not stderr:is_closing() then stderr:close() end
    if handle and not handle:is_closing() then handle:close() end
    vim.schedule(function()
      if pending ~= '' then
        on_lines({ pending })
        pending = ''
      end
      on_exit(code)
    end)
  end)

  if not handle then
    vim.schedule(function() on_exit(-1) end)
    return { kill = function() end }
  end

  stdout:read_start(function(err, data)
    if err or not data then return end
    pending = pending .. data
    local last_nl = pending:find('\n[^\n]*$') or pending:find('\n$')
    if not last_nl then return end
    local complete = pending:sub(1, last_nl)
    pending = pending:sub(last_nl + 1)
    local lines = {}
    for line in complete:gmatch('([^\n]*)\n') do
      lines[#lines + 1] = line
    end
    if #lines > 0 then
      vim.schedule(function() on_lines(lines) end)
    end
  end)

  -- Drain stderr quietly so the pipe doesn't fill.
  stderr:read_start(function(_, _) end)

  return {
    kill = function()
      if handle and not handle:is_closing() then
        pcall(handle.kill, handle, 'sigterm')
      end
    end,
  }
end

return M
