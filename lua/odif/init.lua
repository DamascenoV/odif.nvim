--- odif: a fido-horizontal picker for Neovim, rendered entirely inside
--- the `vim._core.ui2` cmdline buffer. No floating windows.

local M = {}

---@class odif.Source
---@field name? string
---@field items string[]|fun(set: fun(items: any[])) Either an array or
---  an async producer that calls `set(items)` when ready.
---@field format_item? fun(item: any): string
---@field choose? fun(item: any)
---@field choose_literal? fun(text: string)
---@field preview? fun(item: any, target_win: integer)
---@field live? boolean If true, query changes go to `refresh` instead of
---  the local matcher; the source owns filtering.
---@field refresh? fun(query: string) Required for live sources.

---@class odif.Config
---@field prompt string
---@field separator string
---@field hl table<string, string>
---@field delay { busy: integer, async: integer }
---@field mappings table<string, string>

---@type odif.Config
M.config = {
  prompt = 'odif❭ ',
  separator = ' │ ',
  -- Maximum number of cmdline rows the picker is allowed to expand to.
  -- Honour the same value you pass to ui2's `msg.cmd.height`.
  max_height = 2,
  hl = {
    prompt = 'Question',
    query = 'Normal',
    match = 'Normal',
    current = 'CursorLineNr',
    overflow = 'Comment',
    busy = 'WarningMsg',
  },
  delay = { busy = 80, async = 10 },
  mappings = {}, -- reserved
}

--- Built-in source registry; populated by `:Odif <name>`.
M.registry = {}

--- Currently active picker state, or nil.
---@type odif.State|nil
M._active = nil

--- Merge user opts into defaults. Idempotent.
---@param opts? odif.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})

  -- Ensure ui2 is enabled. ui2 is experimental and lives at vim._core.ui2.
  local ok, ui2 = pcall(require, 'vim._core.ui2')
  if not ok then
    vim.notify('[odif] vim._core.ui2 not available — needs Neovim 0.12+', vim.log.levels.ERROR)
    return
  end
  if ui2.cfg.enable == nil or ui2.bufs.cmd == -1 then ui2.enable({ enable = true }) end

  -- Register built-in sources lazily.
  M.registry.buffers = require('odif.source.buffers')
  M.registry.files = require('odif.source.files')
  M.registry.oldfiles = require('odif.source.oldfiles')
  M.registry.help = require('odif.source.help')
  M.registry.lsp_symbols = require('odif.source.lsp_symbols')
  M.registry.grep = require('odif.source.grep')
end

--- Start a picker session.
---@param opts { source: odif.Source, initial_query?: string }
---@return any|nil chosen item, or nil if aborted
function M.start(opts)
  assert(type(opts) == 'table' and type(opts.source) == 'table', 'odif.start: opts.source is required')
  if M._active then M.stop() end
  local chosen, snapshot = require('odif.controller').run(opts.source, M.config, { initial_query = opts.initial_query })
  M._last_session = {
    source = opts.source,
    query = (snapshot and snapshot.query) or '',
  }
  return chosen
end

--- Re-open the most recent picker with its previous query pre-populated.
function M.resume()
  if not M._last_session then
    vim.notify('[odif] no previous picker session', vim.log.levels.WARN)
    return
  end
  return M.start({
    source = M._last_session.source,
    initial_query = M._last_session.query,
  })
end

--- Stop the active picker, if any.
function M.stop()
  if M._active then M._active.aborted = true end
end

--- True when a picker session is in progress.
function M.is_active() return M._active ~= nil end

-- ---------------------------------------------------------------------
-- Async / streaming API (Phase 3)
-- ---------------------------------------------------------------------

local function project_one(state, item)
  if type(item) == 'string' then return item end
  local fmt = state.source.format_item or tostring
  return fmt(item)
end

--- Re-run match for the active picker (async; called by controller too).
---@param state odif.State
function M._refresh(state)
  -- "Live" sources own filtering themselves. Only (re)schedule the
  -- source.refresh call when the QUERY has changed; calls triggered by
  -- streaming appends or selection navigation just refresh the strip.
  if state.source.live then
    local query_changed = state.querytick ~= state._live_querytick
    if query_changed then
      state._live_querytick = state.querytick
      if state._refresh_timer and not state._refresh_timer:is_closing() then
        state._refresh_timer:stop()
        state._refresh_timer:close()
      end
      state._refresh_timer = vim.uv.new_timer()
      state._refresh_timer:start(
        120,
        0,
        vim.schedule_wrap(function()
          if M._active == state and state.source.refresh then state.source.refresh(state.query) end
        end)
      )
    end

    -- Identity match over current items.
    state.matches = {}
    for i = 1, #state.stritems do
      state.matches[i] = i
    end
    if #state.matches == 0 then
      state.current_ind = 0
    else
      state.current_ind = math.min(math.max(1, state.current_ind), #state.matches)
    end

    if query_changed then
      -- Snappy typing, no strip flicker while re-spawn is pending.
      require('odif.render').paint_prompt_only(state)
    else
      -- Append batch / cursor move: full repaint to show the strip.
      require('odif.render').paint(state)
    end
    return
  end

  -- Cancel any in-flight match for the previous query/items snapshot.
  if state._match_ticket then state._match_ticket.cancel() end

  -- Capture the tick + item count at scheduling time. The match is stale
  -- if either changes (user typed a new char, or more items streamed in).
  local qt = state.querytick
  local count = #state.stritems

  state._match_ticket = require('odif.match').run_async(state.stritems, state.query, true, {
    is_stale = function() return state.querytick ~= qt or #state.stritems ~= count end,
  }, function(matches)
    if state.querytick ~= qt or #state.stritems ~= count then return end
    state.matches = matches
    if #matches == 0 then
      state.current_ind = 0
    else
      state.current_ind = math.min(math.max(1, state.current_ind), #matches)
      if state.current_ind == 0 then state.current_ind = 1 end
    end
    require('odif.render').paint(state)
  end)

  -- Paint immediately with stale matches so the prompt/query feel snappy
  -- and the strip updates as soon as the async pass completes.
  require('odif.render').paint(state)
end

--- Replace the active picker's items.
---@param items any[]
function M.set_items(items)
  local state = M._active
  if not state then return end
  state.items = items
  state.stritems = {}
  for i, it in ipairs(items) do
    state.stritems[i] = project_one(state, it)
  end
  M._refresh(state)
end

--- Append items to the active picker (for streaming sources).
--- Coalesces rapid appends into a single repaint every ~60ms to avoid
--- flicker while a process streams thousands of lines.
---@param new_items any[]
function M.append_items(new_items)
  local state = M._active
  if not state or not new_items or #new_items == 0 then return end
  local base = #state.items
  for i, it in ipairs(new_items) do
    state.items[base + i] = it
    state.stritems[base + i] = project_one(state, it)
  end
  -- Throttle: if a repaint is already pending, just let it pick up the
  -- newly-appended items when it fires.
  if state._paint_timer then return end
  state._paint_timer = vim.uv.new_timer()
  state._paint_timer:start(
    60,
    0,
    vim.schedule_wrap(function()
      if state._paint_timer then
        pcall(state._paint_timer.stop, state._paint_timer)
        pcall(state._paint_timer.close, state._paint_timer)
        state._paint_timer = nil
      end
      if M._active == state then M._refresh(state) end
    end)
  )
end

--- Spawn a process; stream its stdout lines into the picker as items.
--- Kills any previous spawn on this picker first.
---@param cmd string[]
function M.set_items_from_cli(cmd)
  local state = M._active
  if not state then return end
  if state._spawn then state._spawn.kill() end

  -- Clear silently. Don't paint an empty "(no match)" state — wait for
  -- the first batch (or process exit) to trigger a real paint.
  state.items = {}
  state.stritems = {}
  state.matches = {}
  state.current_ind = 0
  state.busy = true

  state._spawn = require('odif.spawn').lines(cmd, function(lines) M.append_items(lines) end, function(_)
    if M._active == state then
      state.busy = false
      -- If process produced no output at all, paint the empty state now.
      if #state.items == 0 then require('odif.render').paint(state) end
    end
  end)
end

--- Drop-in replacement for `vim.ui.select`. Opt-in via:
---   vim.ui.select = require('odif').ui_select
---@param items any[]
---@param opts { prompt?: string, format_item?: fun(it:any):string }|nil
---@param on_choice fun(item: any|nil, index: integer|nil)
function M.ui_select(items, opts, on_choice)
  opts = opts or {}
  local format = opts.format_item or tostring
  local entries = {}
  for i, it in ipairs(items) do
    entries[i] = { text = format(it), item = it, index = i }
  end
  M.start({
    source = {
      name = (opts.prompt and tostring(opts.prompt)) or 'select',
      items = entries,
      format_item = function(e) return e.text end,
      choose = function(e)
        if on_choice then on_choice(e and e.item, e and e.index) end
      end,
    },
  })
end

return M
