--- Lightweight, non-permanent file previews.
---
--- We keep ONE reusable unlisted+scratch buffer for the session. Source
--- preview() callbacks call `M.show(target_win, path, lnum, col)`; we read
--- the file into the scratch buffer (no `:edit`, no listed buffer), set
--- filetype for syntax highlighting, and display it in the target window.
---
--- On session end the controller calls `M.dispose()` and the scratch
--- buffer is wiped — so previewing never pollutes :ls.

local M = {}

local scratch_buf = nil -- integer|nil, the reusable preview buffer
local current_path = nil -- last path loaded into scratch_buf

--- Get-or-create the scratch buffer.
---@return integer
local function ensure_buf()
  if scratch_buf and vim.api.nvim_buf_is_valid(scratch_buf) then return scratch_buf end
  scratch_buf = vim.api.nvim_create_buf(false, true) -- not listed, scratch
  vim.bo[scratch_buf].bufhidden = 'hide'
  vim.bo[scratch_buf].buftype = 'nofile'
  vim.bo[scratch_buf].swapfile = false
  vim.api.nvim_buf_set_name(scratch_buf, '[odif preview]')
  current_path = nil
  return scratch_buf
end

--- Read at most `limit` lines from `path`. Returns nil on failure.
---@param path string
---@param limit integer
---@return string[]|nil
local function read_lines(path, limit)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local data = fh:read(1024 * 1024) -- cap at 1 MiB for huge files
  fh:close()
  if not data then return {} end
  local lines = vim.split(data, '\n', { plain = true })
  if #lines > limit then
    for i = #lines, limit + 1, -1 do
      lines[i] = nil
    end
    lines[limit + 1] = '… (file truncated)'
  end
  -- Strip trailing CRs.
  for i, l in ipairs(lines) do
    if l:sub(-1) == '\r' then lines[i] = l:sub(1, -2) end
  end
  return lines
end

--- Show `path` in `target_win` at `lnum`/`col`, without listing a buffer.
---@param target_win integer
---@param path string
---@param lnum integer|nil
---@param col integer|nil
function M.show(target_win, path, lnum, col)
  if not vim.api.nvim_win_is_valid(target_win) then return end
  if not path or path == '' or vim.fn.filereadable(path) ~= 1 then return end

  local buf = ensure_buf()

  -- Only re-read the file if we switched paths (or this is the first time).
  if current_path ~= path then
    local lines = read_lines(path, 10000)
    if not lines then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    -- Filetype detection for syntax highlighting.
    local ft = vim.filetype.match({ filename = path }) or ''
    vim.bo[buf].filetype = ft
    current_path = path
  end

  -- Display in the target window.
  if vim.api.nvim_win_get_buf(target_win) ~= buf then pcall(vim.api.nvim_win_set_buf, target_win, buf) end

  -- Centre on the requested line.
  if lnum and lnum >= 1 then
    local total = vim.api.nvim_buf_line_count(buf)
    local row = math.min(lnum, total)
    pcall(vim.api.nvim_win_set_cursor, target_win, { row, math.max(0, (col or 1) - 1) })
    vim.api.nvim_win_call(target_win, function() vim.cmd('normal! zz') end)
  end
end

--- Wipe the scratch buffer. Called at session end by the controller.
function M.dispose()
  if scratch_buf and vim.api.nvim_buf_is_valid(scratch_buf) then
    pcall(vim.api.nvim_buf_delete, scratch_buf, { force = true })
  end
  scratch_buf = nil
  current_path = nil
end

return M
