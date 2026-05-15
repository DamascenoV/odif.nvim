--- Picker event loop.
--- Uses vim.fn.getcharstr() (blocking, but yields to the event loop) the
--- same way mini.pick does. No floating windows; we paint directly into
--- the ui2 cmdline buffer.

local bridge = require('odif.ui2_bridge')
local render = require('odif.render')

local M = {}

---@class odif.State
---@field source odif.Source
---@field config table
---@field ctx table        ui2 bridge context (buf/win/ns)
---@field stritems string[]
---@field items any[]
---@field query string
---@field caret integer    1-based byte position (1..#query+1)
---@field querytick integer monotonic counter, bumped on every query change
---@field matches integer[]   indices into stritems, sorted best-first
---@field current_ind integer cursor position inside `matches`
---@field busy boolean
---@field aborted boolean
---@field target_win integer
---@field target_buf integer
---@field target_pos integer[]
---@field preview boolean
---@field last_preview_ind integer|nil
---@field _spawn { kill: fun() }|nil
---@field _match_ticket { cancel: fun() }|nil
---@field _refresh_timer any|nil    -- uv_timer_t
---@field _paint_timer any|nil      -- uv_timer_t
---@field _live_querytick integer|nil

--- Build string projections for items.
---@param items any[]
---@param format fun(item:any):string|nil
---@return string[]
local function project(items, format)
  format = format or tostring
  local out = {}
  for i, it in ipairs(items) do
    if type(it) == 'string' then
      out[i] = it
    else
      out[i] = format(it)
    end
  end
  return out
end

--- Recompute `state.matches` from current query (delegates to async refresh).
local function rematch(state) require('odif')._refresh(state) end

--- If preview is on and `current_ind` has moved, ask the source to preview.
local function maybe_preview(state)
  if not state.preview then return end
  local ind = state.current_ind
  if ind == state.last_preview_ind then return end
  state.last_preview_ind = ind
  local item = ind > 0 and state.items[state.matches[ind]] or nil
  if item and state.source.preview and vim.api.nvim_win_is_valid(state.target_win) then
    pcall(state.source.preview, item, state.target_win)
  end
end

--- Walk `n` UTF-8 code points left (n<0) or right (n>0) from byte position
--- `byte` inside `s`. Returns the new byte position, clamped to [1, #s+1].
local function walk_utf8(s, byte, n)
  if n == 0 then return byte end
  if n > 0 then
    for _ = 1, n do
      if byte > #s then break end
      local b = s:byte(byte) or 0
      local len = (b < 0x80) and 1
        or (b < 0xc0) and 1 -- shouldn't happen on a lead byte; safety
        or (b < 0xe0) and 2
        or (b < 0xf0) and 3
        or 4
      byte = math.min(#s + 1, byte + len)
    end
  else
    for _ = 1, -n do
      if byte <= 1 then break end
      byte = byte - 1
      while byte > 1 and (s:byte(byte) or 0) >= 0x80 and (s:byte(byte) or 0) < 0xc0 do
        byte = byte - 1
      end
    end
  end
  return byte
end

--- Mutate query: replace [a, b) with `repl`, place caret at `a + #repl`.
local function splice(state, a, b, repl)
  state.query = state.query:sub(1, a - 1) .. repl .. state.query:sub(b)
  state.caret = a + #repl
  state.querytick = state.querytick + 1
  rematch(state)
end

--- Translate a getcharstr() result into a logical action name.
---@param ch string
---@return string action, string|nil insert_char
local function classify(ch)
  if ch == '' then return 'noop' end
  -- Handle terminal/control bytes.
  local b = ch:byte(1)
  if ch == '\27' then return 'abort' end -- <Esc>
  if ch == '\3' then return 'abort' end -- <C-c>
  -- NB: \n (0x0a) is <C-j>, not <CR>. fido binds it to choose_literal.
  if ch == '\10' then return 'choose_literal' end -- <C-j>  (fido M-j parity)
  if ch == '\r' then return 'choose' end -- <CR>
  if ch == '\t' then return 'preview_toggle' end -- <Tab>
  if ch == '\8' or ch == '\127' then return 'bs' end
  if ch == '\14' then return 'next' end -- <C-n>
  if ch == '\16' then return 'prev' end -- <C-p>
  if ch == '\19' then return 'next' end -- <C-s>  (fido)
  if ch == '\18' then return 'prev' end -- <C-r>  (fido)
  if ch == '\21' then return 'clear' end -- <C-u>
  if ch == '\23' then return 'word_back' end -- <C-w>
  if ch == '\4' then return 'choose_literal' end -- <C-d>  (fido)

  -- Multi-byte / special keys returned by getcharstr() as <80>... sequences
  -- come back from vim.fn.keytrans for legibility.
  local k = vim.fn.keytrans(ch)
  if k == '<Down>' then return 'next' end
  if k == '<Up>' then return 'prev' end
  if k == '<Right>' then return 'caret_right' end -- caret in query
  if k == '<Left>' then return 'caret_left' end -- caret in query
  if k == '<Home>' then return 'caret_home' end
  if k == '<End>' then return 'caret_end' end
  if k == '<BS>' then return 'bs' end
  if k == '<Del>' then return 'del' end
  if k == '<CR>' then return 'choose' end
  if k == '<Esc>' then return 'abort' end
  if k == '<C-Home>' then return 'first' end
  if k == '<C-End>' then return 'last' end

  -- Anything else printable goes into the query.
  if b and b >= 0x20 and b < 0x7f then return 'insert', ch end
  -- UTF-8 lead bytes too.
  if b and b >= 0x80 then return 'insert', ch end
  return 'noop'
end

---@param source odif.Source
---@param config table
---@param opts? { initial_query?: string }
---@return any|nil chosen, { query: string }|nil snapshot
function M.run(source, config, opts)
  opts = opts or {}
  -- Capture the user's window BEFORE acquiring the cmd window, so we
  -- know where to preview / open chosen items.
  local target_win = vim.api.nvim_get_current_win()
  local target_buf = vim.api.nvim_win_get_buf(target_win)
  local target_pos = vim.api.nvim_win_get_cursor(target_win)

  local ctx = bridge.acquire()
  bridge.ensure_visible(ctx, 1)

  -- Resolve items (sync only in v0).
  ---@type any[]
  local items = {}
  if type(source.items) == 'function' then
    ---@type any[]?
    local resolved
    (source.items --[[@as fun(set: fun(items: any[]))]])(function(it) resolved = it end)
    items = resolved or {}
  elseif type(source.items) == 'table' then
    items = source.items --[[@as any[] ]]
  end

  local initial_query = opts.initial_query or ''

  ---@type odif.State
  local state = {
    source = source,
    config = config,
    ctx = ctx,
    items = items,
    stritems = project(items, source.format_item),
    query = initial_query,
    caret = #initial_query + 1,
    querytick = 0,
    matches = {},
    current_ind = 1,
    busy = false,
    aborted = false,
    -- preview / target window
    target_win = target_win,
    target_buf = target_buf,
    target_pos = target_pos,
    preview = false, -- preview toggle
    last_preview_ind = nil, -- to avoid re-previewing the same item
  }
  require('odif')._active = state
  rematch(state)
  render.paint(state)

  local chosen ---@type any|nil

  while not state.aborted do
    -- getcharstr yields to the event loop, processing scheduled callbacks.
    local ok, ch = pcall(vim.fn.getcharstr)
    if not ok then break end
    local action, arg = classify(ch)

    if action == 'abort' then
      break
    elseif action == 'choose' then
      if state.current_ind > 0 and state.matches[state.current_ind] then
        chosen = state.items[state.matches[state.current_ind]]
      end
      break
    elseif action == 'choose_literal' then
      if source.choose_literal then source.choose_literal(state.query) end
      break
    elseif action == 'insert' then
      splice(state, state.caret, state.caret, arg)
    elseif action == 'bs' then
      if state.caret > 1 then
        local new_caret = walk_utf8(state.query, state.caret, -1)
        splice(state, new_caret, state.caret, '')
      end
    elseif action == 'del' then
      if state.caret <= #state.query then
        local nxt = walk_utf8(state.query, state.caret, 1)
        splice(state, state.caret, nxt, '')
      end
    elseif action == 'clear' then
      splice(state, 1, #state.query + 1, '')
    elseif action == 'word_back' then
      -- delete \S*\s* immediately before caret
      local left = state.query:sub(1, state.caret - 1)
      local right = state.query:sub(state.caret)
      local trimmed = left:gsub('%S*%s*$', '', 1)
      state.query = trimmed .. right
      state.caret = #trimmed + 1
      state.querytick = state.querytick + 1
      rematch(state)
    elseif action == 'caret_left' then
      state.caret = walk_utf8(state.query, state.caret, -1)
    elseif action == 'caret_right' then
      state.caret = walk_utf8(state.query, state.caret, 1)
    elseif action == 'caret_home' then
      state.caret = 1
    elseif action == 'caret_end' then
      state.caret = #state.query + 1
    elseif action == 'next' then
      if #state.matches > 0 then state.current_ind = state.current_ind % #state.matches + 1 end
    elseif action == 'prev' then
      if #state.matches > 0 then state.current_ind = (state.current_ind - 2) % #state.matches + 1 end
    elseif action == 'first' then
      if #state.matches > 0 then state.current_ind = 1 end
    elseif action == 'last' then
      if #state.matches > 0 then state.current_ind = #state.matches end
    elseif action == 'preview_toggle' then
      state.preview = not state.preview
      state.last_preview_ind = nil
      if
        not state.preview
        and vim.api.nvim_win_is_valid(state.target_win)
        and vim.api.nvim_buf_is_valid(state.target_buf)
      then
        -- Restore the target window's original buffer/cursor.
        pcall(vim.api.nvim_win_set_buf, state.target_win, state.target_buf)
        pcall(vim.api.nvim_win_set_cursor, state.target_win, state.target_pos)
      end
    end

    maybe_preview(state)
    render.paint(state)
  end

  if state._spawn then pcall(state._spawn.kill) end
  for _, key in ipairs({ '_refresh_timer', '_paint_timer' }) do
    local t = state[key]
    if t and not t:is_closing() then
      pcall(t.stop, t)
      pcall(t.close, t)
    end
    state[key] = nil
  end

  -- If we previewed but the user aborted, restore the target window.
  if
    state.preview
    and chosen == nil
    and vim.api.nvim_win_is_valid(state.target_win)
    and vim.api.nvim_buf_is_valid(state.target_buf)
  then
    pcall(vim.api.nvim_win_set_buf, state.target_win, state.target_buf)
    pcall(vim.api.nvim_win_set_cursor, state.target_win, state.target_pos)
  end

  bridge.release(ctx)
  require('odif')._active = nil

  if chosen ~= nil and source.choose then source.choose(chosen) end
  return chosen, { query = state.query }
end

return M
