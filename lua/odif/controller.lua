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

--- Default key → action table. Keys may be either:
---   - a single raw byte (e.g. '\r', '\27', '\14')
---   - a `vim.fn.keytrans` form (e.g. '<CR>', '<Down>', '<C-x>')
--- Users override this via `config.mappings`.
local DEFAULT_MAPPINGS = {
  -- Control bytes
  ['\27'] = 'abort', -- <Esc>
  ['\3'] = 'abort', -- <C-c>
  ['\10'] = 'choose_literal', -- <C-j>  (fido M-j parity)
  ['\r'] = 'choose', -- <CR>
  ['\t'] = 'preview_toggle', -- <Tab>
  ['\8'] = 'bs',
  ['\127'] = 'bs',
  ['\14'] = 'next', -- <C-n>
  ['\16'] = 'prev', -- <C-p>
  ['\19'] = 'next', -- <C-s>  (fido)
  ['\18'] = 'prev', -- <C-r>  (fido)
  ['\21'] = 'clear', -- <C-u>
  ['\23'] = 'word_back', -- <C-w>
  ['\4'] = 'choose_literal', -- <C-d>  (fido)

  -- keytrans forms
  ['<Down>'] = 'next',
  ['<Up>'] = 'prev',
  ['<Right>'] = 'caret_right',
  ['<Left>'] = 'caret_left',
  ['<Home>'] = 'caret_home',
  ['<End>'] = 'caret_end',
  ['<BS>'] = 'bs',
  ['<Del>'] = 'del',
  ['<CR>'] = 'choose',
  ['<Esc>'] = 'abort',
  ['<C-Home>'] = 'first',
  ['<C-End>'] = 'last',
  ['<Tab>'] = 'preview_toggle',
}

--- Canonicalize a mapping key. Raw bytes pass through. keytrans forms
--- (e.g. `<C-x>`) are round-tripped through nvim_replace_termcodes +
--- keytrans so we always store the form keytrans will actually emit at
--- classification time (e.g. `<C-X>` with uppercase letter).
---@param key string
---@return string
local function normalize_key(key)
  if type(key) ~= 'string' or key == '' then return key end
  if key:sub(1, 1) ~= '<' then return key end
  local ok, raw = pcall(vim.api.nvim_replace_termcodes, key, true, true, true)
  if not ok or raw == '' or raw == key then return key end
  local ok2, k2 = pcall(vim.fn.keytrans, raw)
  if not ok2 or type(k2) ~= 'string' or k2 == '' then return key end
  return k2
end

--- Build the effective key→action table by merging user overrides on top
--- of the defaults. A user value of `false` removes a binding.
---@param user_mappings table<string, string|false>|nil
local function build_mappings(user_mappings)
  local out = {}
  for k, v in pairs(DEFAULT_MAPPINGS) do
    out[normalize_key(k)] = v
  end
  for k, v in pairs(user_mappings or {}) do
    local nk = normalize_key(k)
    if v == false then
      out[nk] = nil
    else
      out[nk] = v
    end
  end
  return out
end

--- Translate a getcharstr() result into a logical action name.
---@param ch string
---@param mappings table<string, string>
---@return string action, string|nil insert_char
local function classify(ch, mappings)
  if ch == '' then return 'noop' end
  -- 1) Raw byte lookup (covers control chars and bare ASCII).
  local act = mappings[ch]
  if act then return act end
  -- 2) keytrans lookup for special keys (<Down>, <C-x>, …).
  local k = vim.fn.keytrans(ch)
  act = mappings[k]
  if act then return act end
  -- 3) Insert printable / UTF-8 lead bytes into the query.
  local b = ch:byte(1)
  if b and (b >= 0x20 and b < 0x7f) then return 'insert', ch end
  if b and b >= 0x80 then return 'insert', ch end
  return 'noop'
end

-- Exposed for tests.
M._classify = classify
M._build_mappings = build_mappings
M._DEFAULT_MAPPINGS = DEFAULT_MAPPINGS

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

  local mappings = build_mappings(config.mappings)
  local chosen ---@type any|nil

  while not state.aborted do
    -- getcharstr yields to the event loop, processing scheduled callbacks.
    local ok, ch = pcall(vim.fn.getcharstr)
    if not ok then break end
    local action, arg = classify(ch, mappings)

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

  -- Tear down the scratch preview buffer (if any).
  require('odif.preview').dispose()

  bridge.release(ctx)
  require('odif')._active = nil

  if chosen ~= nil and source.choose then source.choose(chosen) end
  return chosen, { query = state.query }
end

return M
