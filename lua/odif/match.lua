--- Fuzzy matcher. Synchronous v0 — bucket-sorted by (width, start).
--- Lifted from mini.pick's algorithm, simplified.

local M = {}

--- Find the smallest window in `s` containing all chars of `query` in order.
---@param s string lowercased candidate
---@param query string lowercased query (no spaces)
---@return integer|nil width, integer|nil start
local function fuzzy_window(s, query)
  if #query == 0 then return 0, 1 end
  local len = #query

  -- Forward pass: find any matching window.
  local first, last
  do
    local qi = 1
    for i = 1, #s do
      if s:byte(i) == query:byte(qi) then
        if qi == 1 then first = i end
        qi = qi + 1
        if qi > len then
          last = i
          break
        end
      end
    end
    if not last then return nil end
  end

  -- Slide the start rightward to minimise (last - first).
  local best_first, best_last = first, last
  while true do
    -- Try to find a later occurrence of query[1] still <= best_last.
    local qi, new_first, new_last = 1, nil, nil
    local start = best_first + 1
    for i = start, #s do
      if s:byte(i) == query:byte(qi) then
        if qi == 1 then new_first = i end
        qi = qi + 1
        if qi > len then
          new_last = i
          break
        end
      end
    end
    if not new_last then break end
    if (new_last - new_first) < (best_last - best_first) then
      best_first, best_last = new_first, new_last
    else
      break
    end
  end

  return best_last - best_first + 1, best_first
end

--- Match items against query. Returns sorted indices (best first).
---@param stritems string[]
---@param query string
---@param ignorecase boolean
---@return integer[] indices
function M.run(stritems, query, ignorecase)
  if query == '' then
    local out = {}
    for i = 1, #stritems do
      out[i] = i
    end
    return out
  end

  local q = ignorecase and query:lower() or query
  -- Strip whitespace for v0 (no grouped queries yet).
  q = q:gsub('%s+', '')
  if q == '' then
    local out = {}
    for i = 1, #stritems do
      out[i] = i
    end
    return out
  end

  local hits = {} -- { {width, start, idx} }
  local max_w, max_s = 0, 0
  for i, s in ipairs(stritems) do
    local cand = ignorecase and s:lower() or s
    local w, st = fuzzy_window(cand, q)
    if w and st then
      hits[#hits + 1] = { w, st, i }
      if w > max_w then max_w = w end
      if st > max_s then max_s = st end
    end
  end

  -- Bucket sort by width then start (stable, O(n)).
  table.sort(hits, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[3] < b[3]
  end)

  local out = {}
  for i, h in ipairs(hits) do
    out[i] = h[3]
  end
  return out
end

--- Async (chunked) match. Processes `chunk_size` items per event-loop
--- tick, yielding via `vim.schedule` between chunks. Aborts as soon as
--- `is_stale()` returns true. Calls `on_done(matches)` when finished.
---
---@param stritems string[]
---@param query string
---@param ignorecase boolean
---@param opts { chunk_size?: integer, is_stale?: fun(): boolean }
---@param on_done fun(matches: integer[])
---@return { cancel: fun() }
function M.run_async(stritems, query, ignorecase, opts, on_done)
  opts = opts or {}
  local chunk = opts.chunk_size or 5000
  local stale = opts.is_stale or function() return false end

  local q = ignorecase and query:lower() or query
  q = q:gsub('%s+', '')

  -- Empty query → identity, finish synchronously on the next tick.
  if q == '' then
    vim.schedule(function()
      if stale() then return end
      local out = {}
      for i = 1, #stritems do
        out[i] = i
      end
      on_done(out)
    end)
    return { cancel = function() end }
  end

  local hits = {}
  local i = 1
  local cancelled = false

  local function step()
    if cancelled or stale() then return end
    local stop = math.min(#stritems, i + chunk - 1)
    for j = i, stop do
      local cand = ignorecase and stritems[j]:lower() or stritems[j]
      local w, st = fuzzy_window(cand, q)
      if w and st then hits[#hits + 1] = { w, st, j } end
    end
    i = stop + 1
    if i > #stritems then
      if cancelled or stale() then return end
      table.sort(hits, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        if a[2] ~= b[2] then return a[2] < b[2] end
        return a[3] < b[3]
      end)
      local out = {}
      for k, h in ipairs(hits) do
        out[k] = h[3]
      end
      on_done(out)
    else
      vim.schedule(step)
    end
  end
  vim.schedule(step)

  return { cancel = function() cancelled = true end }
end

return M
