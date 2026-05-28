--- Render a fido-horizontal picker into the ui2 cmdline buffer.
--- Layout:
---   row 1: <prompt><query>  m1 │ [current] │ m2 │ m3 │ m4 │ …
---   row 2: │ m5 │ m6 │ m7 │ m8 │ … (continues if max_height > 1)
---
--- Candidate chunks are materialised as real cmd-buffer lines (instead
--- of wrapped inline virtual text) so ui2 clipping stays deterministic.

local M = {}

--- Truncate `s` to at most `max` display cells, appending `…` if cut.
--- Returns `s` unchanged when `max` is falsy/<=0 or the string already fits.
---@param s string
---@param max integer|nil
---@return string
local function truncate(s, max)
  if not max or max <= 0 then return s end
  if vim.fn.strdisplaywidth(s) <= max then return s end
  -- Walk forward by display cells, character by character.
  local chars = vim.fn.split(s, '\\zs')
  local out, width = {}, 0
  local cap = max - 1 -- leave room for the ellipsis
  for _, ch in ipairs(chars) do
    local w = vim.fn.strdisplaywidth(ch)
    if width + w > cap then break end
    out[#out + 1] = ch
    width = width + w
  end
  return table.concat(out) .. '…'
end

--- Resolve the prompt string for a session:
---   1. `source.prompt` if set
---   2. `<source.name>: ` if `cfg.prompt_from_source` is true and name exists
---   3. `cfg.prompt`
---@param state odif.State
---@return string
function M.prompt_for(state)
  local src = state.source
  local cfg = state.config
  if src and src.prompt and src.prompt ~= '' then return src.prompt end
  if cfg.prompt_from_source and src and src.name and src.name ~= '' then return src.name .. ': ' end
  return cfg.prompt
end

---@param state odif.State
function M.paint(state)
  local ctx = state.ctx
  local cfg = state.config
  local prompt = M.prompt_for(state)
  local query = state.query
  local max_height = math.max(1, cfg.max_height or 2)

  local line = prompt .. query
  local caret = state.caret or (#query + 1)

  -- Reset extmarks. Lines are replaced after the candidate strip is built.
  vim.api.nvim_buf_clear_namespace(ctx.buf, ctx.ns, 0, -1)

  -- Build the candidate strip as a list of {text, hl} chunks.
  local sep = cfg.separator
  local matches = state.matches
  local cur = state.current_ind
  local stritems = state.stritems
  local win_w = vim.api.nvim_win_get_width(ctx.win)

  -- Pixel/cell budget for the strip: max_height rows of width win_w,
  -- minus what's already occupied on row 1 by prompt+query, minus a
  -- small initial gap.
  local prompt_w = vim.fn.strdisplaywidth(line)
  local gap = 2
  local budget = max_height * win_w - prompt_w - gap
  if budget < 10 then budget = 10 end

  local chunks = {}
  local function push(text, hl) chunks[#chunks + 1] = { text, hl } end

  if #matches == 0 then
    push((' '):rep(gap) .. '(no match)', cfg.hl.overflow)
  else
    -- Per-item display cap. Long lines (e.g. grep output) get truncated so
    -- multiple results still fit on the strip; matching still uses the
    -- full string in `stritems`.
    local cap = cfg.max_item_width
    local function disp(idx) return truncate(stritems[matches[idx]], cap) end

    -- Greedy outward expansion centred on the current match, just like
    -- Emacs fido — keeps the current candidate visible as you cycle.
    local left, right = cur, cur
    local function w_of(idx) return vim.fn.strdisplaywidth(disp(idx)) end

    local total = w_of(cur)
    while total < budget and (left > 1 or right < #matches) do
      local can_left = left > 1
      local can_right = right < #matches
      if can_right then
        local w = w_of(right + 1) + #sep
        if total + w > budget and can_left then
          local wl = w_of(left - 1) + #sep
          if total + wl > budget then break end
          left = left - 1
          total = total + wl
        else
          if total + w > budget then break end
          right = right + 1
          total = total + w
        end
      elseif can_left then
        local wl = w_of(left - 1) + #sep
        if total + wl > budget then break end
        left = left - 1
        total = total + wl
      else
        break
      end
    end

    -- Leading gap (so the strip doesn't kiss the query).
    push((' '):rep(gap), 'Normal')
    if left > 1 then push('… ', cfg.hl.overflow) end
    -- Current match: highlighted with cfg.hl.current (PmenuSel by default).
    for i = left, right do
      if i > left then push(sep, cfg.hl.overflow) end
      local s = disp(i)
      if i == cur then
        push(s, cfg.hl.current)
      else
        push(s, cfg.hl.match)
      end
    end
    if right < #matches then push(' …', cfg.hl.overflow) end

    -- Match count: "M/N" like Emacs fido.
    if cfg.show_count ~= false and #matches > 0 then
      push(' ' .. cur .. '/' .. #matches, cfg.hl.overflow)
    end
  end

  -- 4) Materialise the strip into real cmd-buffer lines instead of one
  -- huge inline virtual-text run. ui2 sometimes lets wrapped inline virtual
  -- text bleed into normal editor rows when a very long strip changes size;
  -- physical lines keep clipping/height deterministic.
  local lines = { line }
  local widths = { prompt_w }
  local marks = {}
  local function append_chunk(text, hl)
    if text == '' then return end
    local width = vim.fn.strdisplaywidth(text)
    local row = #lines
    if widths[row] > 0 and widths[row] + width > win_w and row < max_height then
      lines[#lines + 1] = ''
      widths[#widths + 1] = 0
      row = #lines
    end
    local col = #lines[row]
    lines[row] = lines[row] .. text
    widths[row] = widths[row] + width
    if hl and hl ~= 'Normal' then marks[#marks + 1] = { row = row - 1, col = col, end_col = col + #text, hl = hl } end
  end
  for _, chunk in ipairs(chunks) do
    append_chunk(chunk[1], chunk[2])
  end

  vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, lines)

  -- Highlight prompt and candidates.
  vim.api.nvim_buf_set_extmark(ctx.buf, ctx.ns, 0, 0, {
    end_col = #prompt,
    hl_group = state.busy and cfg.hl.busy or cfg.hl.prompt,
    invalidate = true,
    undo_restore = false,
  })
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(ctx.buf, ctx.ns, mark.row, mark.col, {
      end_col = mark.end_col,
      hl_group = mark.hl,
      invalidate = true,
      undo_restore = false,
    })
  end

  -- Mid-string caret marker.
  if caret <= #query then
    vim.api.nvim_buf_set_extmark(ctx.buf, ctx.ns, 0, #prompt + caret - 1, {
      virt_text = { { '▏', cfg.hl.prompt } },
      virt_text_pos = 'inline',
    })
  end

  -- 5) Grow/shrink to the exact number of materialised lines.
  require('odif.ui2_bridge').set_height(ctx, #lines)

  -- 6) Real cursor at caret position inside the query.
  local cursor_col = #prompt + (caret - 1)
  pcall(vim.api.nvim_win_set_cursor, ctx.win, { 1, cursor_col })
  vim.cmd('redraw')
end

--- Repaint only the prompt+query line (cheap; used while a live re-spawn
--- is pending so typing stays snappy without flickering the strip).
---@param state odif.State
function M.paint_prompt_only(state)
  local ctx = state.ctx
  local cfg = state.config
  local prompt = M.prompt_for(state)
  local query = state.query
  local line = prompt .. query

  -- Replace the whole cmd buffer. Old candidate rows must be removed here;
  -- otherwise a live source can leave stale physical rows while the next
  -- process is still spawning.
  vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, { line })
  require('odif.ui2_bridge').set_height(ctx, 1)

  -- Reset extmarks, then re-add prompt + caret marks.
  vim.api.nvim_buf_clear_namespace(ctx.buf, ctx.ns, 0, -1)
  vim.api.nvim_buf_set_extmark(ctx.buf, ctx.ns, 0, 0, {
    end_col = #prompt,
    hl_group = state.busy and cfg.hl.busy or cfg.hl.prompt,
    invalidate = true,
    undo_restore = false,
  })
  local caret = state.caret or (#query + 1)
  if caret <= #query then
    vim.api.nvim_buf_set_extmark(ctx.buf, ctx.ns, 0, #prompt + caret - 1, {
      virt_text = { { '▏', cfg.hl.prompt } },
      virt_text_pos = 'inline',
    })
  end

  pcall(vim.api.nvim_win_set_cursor, ctx.win, { 1, #prompt + (caret - 1) })
  vim.cmd('redraw')
end

return M
