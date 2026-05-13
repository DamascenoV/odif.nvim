--- Render a fido-horizontal picker into the ui2 cmdline buffer.
--- Layout:
---   row 1: <prompt><query>  m1 │ [current] │ m2 │ m3 │ m4 │ …
---   row 2: │ m5 │ m6 │ m7 │ m8 │ … (continues if max_height > 1)
---
--- All candidate chunks are laid out as a single inline virt_text run
--- after the typed query; the cmd window has wrap=true (set by ui2),
--- so the run wraps visually. We grow the cmd window to fit the
--- wrapped text height, capped at `cfg.max_height`.

local M = {}

---@param state odif.State
function M.paint(state)
  local ctx = state.ctx
  local cfg = state.config
  local prompt = cfg.prompt
  local query = state.query
  local max_height = math.max(1, cfg.max_height or 2)

  -- 1) Prompt + query line.
  local line = prompt .. query
  vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, { line })

  -- 2) Reset extmarks.
  vim.api.nvim_buf_clear_namespace(ctx.buf, ctx.ns, 0, -1)

  -- Highlight prompt.
  vim.api.nvim_buf_set_extmark(ctx.buf, ctx.ns, 0, 0, {
    end_col = #prompt,
    hl_group = state.busy and cfg.hl.busy or cfg.hl.prompt,
    invalidate = true,
    undo_restore = false,
  })

  -- Mid-string caret marker.
  local caret = state.caret or (#query + 1)
  if caret <= #query then
    vim.api.nvim_buf_set_extmark(ctx.buf, ctx.ns, 0, #prompt + caret - 1, {
      virt_text = { { '▏', cfg.hl.prompt } },
      virt_text_pos = 'inline',
    })
  end

  -- 3) Build the candidate strip as a list of {text, hl} chunks.
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
    -- Greedy outward expansion centred on the current match, just like
    -- Emacs fido — keeps the current candidate visible as you cycle.
    local left, right = cur, cur
    local function w_of(idx, current)
      local s = stritems[matches[idx]]
      local t = current and ('[' .. s .. ']') or s
      return vim.fn.strdisplaywidth(t)
    end

    local total = w_of(cur, true)
    while total < budget and (left > 1 or right < #matches) do
      local can_left  = left > 1
      local can_right = right < #matches
      if can_right then
        local w = w_of(right + 1, false) + #sep
        if total + w > budget and can_left then
          local wl = w_of(left - 1, false) + #sep
          if total + wl > budget then break end
          left = left - 1; total = total + wl
        else
          if total + w > budget then break end
          right = right + 1; total = total + w
        end
      elseif can_left then
        local wl = w_of(left - 1, false) + #sep
        if total + wl > budget then break end
        left = left - 1; total = total + wl
      else
        break
      end
    end

    -- Leading gap (so the strip doesn't kiss the query).
    push((' '):rep(gap), 'Normal')
    if left > 1 then push('… ', cfg.hl.overflow) end
    for i = left, right do
      if i > left then push(sep, cfg.hl.overflow) end
      local s = stritems[matches[i]]
      if i == cur then
        push('[' .. s .. ']', cfg.hl.current)
      else
        push(s, cfg.hl.match)
      end
    end
    if right < #matches then push(' …', cfg.hl.overflow) end
  end

  -- 4) Place chunks as ONE inline virt_text run after the typed query.
  -- With wrap=true, this wraps onto subsequent rows automatically.
  vim.api.nvim_buf_set_extmark(ctx.buf, ctx.ns, 0, #line, {
    virt_text = chunks,
    virt_text_pos = 'inline',
  })

  -- 5) Grow the cmd window to fit, capped at max_height. Goes through
  -- the bridge so the user's cmdheight is honoured as the lower bound.
  local height = vim.api.nvim_win_text_height(ctx.win, {}).all
  height = math.min(max_height, math.max(1, height))
  require('odif.ui2_bridge').set_height(ctx, height)

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
  local prompt = cfg.prompt
  local query = state.query
  local line = prompt .. query

  -- Replace just the first row of the cmd buffer.
  vim.api.nvim_buf_set_lines(ctx.buf, 0, 1, false, { line })

  -- Reset extmarks on row 0 only, then re-add prompt + caret marks.
  -- We can't clear by row, so we clear our entire ns and re-apply them.
  vim.api.nvim_buf_clear_namespace(ctx.buf, ctx.ns, 0, -1)
  vim.api.nvim_buf_set_extmark(ctx.buf, ctx.ns, 0, 0, {
    end_col = #prompt,
    hl_group = state.busy and cfg.hl.busy or cfg.hl.prompt,
    invalidate = true, undo_restore = false,
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
