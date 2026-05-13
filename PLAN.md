# odif — fido-horizontal picker for Neovim (built on `vim._core.ui2`)

> *odif* = "ido" backwards, with a horizontal twist.
>
> A minimal picker that lives **inside the cmdline** (not a floating window)
> and shows candidates inline, fido-style, on a single horizontal strip.
> Built on Neovim 0.12's experimental `vim._core.ui2` so the prompt and the
> candidate strip share the same surface as `:` and `/`.

---

## 1. Goals & non-goals

### Goals
- **fido-horizontal UX, in the minibuffer**: prompt on the left, candidates
  on the right of the **same cmdline line**, current candidate highlighted;
  `<CR>` picks the current, arrows / `C-n` / `C-p` cycle, `C-j` accepts
  literal input. Exactly like Emacs `fido-mode`.
- **Zero floating windows. Ever.** The picker is rendered *only* into the
  existing `ui2.wins.cmd` window / `ui2.bufs.cmd` buffer using virtual text.
  No `nvim_open_win`, no popup menu, no border, no overlay. If it can't be
  done in the cmdline, it isn't done.
- **Tiny core, pluggable sources** (files, buffers, lsp_symbols, …) modeled
  loosely on `mini.pick`'s `source` table.
- **Async-friendly**: large item sets and `rg`/`fd` streams must not block
  the UI; use coroutines + `vim.schedule` (no real threads).
- **No dependencies** beyond stdlib + ui2.

### Non-goals (v0)
- **No floating windows of any kind** — not for the prompt, not for the
  candidate strip, not for previews, not as a fallback. The whole picker
  is the cmdline buffer plus extmarks.
- No vertical view, no preview, no marked-multiselect, no info pane. These
  belong to a different plugin; fido-horizontal in the minibuffer is the
  whole point.
- No `vim.ui.select` takeover in v0 (opt-in later).
- No fancy scoring (start with simple fzy-style; revisit if too slow on
  100k items).

---

## 2. Why ui2?

`vim._core.ui2` already owns the cmdline area. From `ui2.lua`:

- It calls `vim.ui_attach(ns, { ext_messages = true, set_cmdheight = false }, …)`
  and renders the cmdline into a **real floating window** anchored to
  `laststatus` (`ui.wins.cmd`) backed by a real buffer (`ui.bufs.cmd`,
  `filetype=cmd`).
- `ui2.cmdline.cmdline_show` writes the prompt+content into that buffer
  every time the cmdline updates (`firstc .. prompt .. cmdbuff`) and grows
  the window with `win_config(win, false, height)`.
- `cmdline_pos` moves the cursor inside that buffer.

That gives us three things for free:
1. A buffer/window pair living exactly where Emacs's minibuffer lives.
2. A `FileType cmd` autocmd hook to drop in our keymaps & extmarks.
3. Treesitter highlighting of typed text (already done for `:` lines).

We don't need to *replace* the cmdline. We **piggy-back**: open a normal
prompt via `vim.fn.input`/`getcmdline` on the cmd buffer, then paint our
candidate strip with virtual text on the same line, and intercept keys.

---

## 3. Architecture

```diagram
╭──────────────────────────────────────────────────────────────────────╮
│                         odif.start(opts)                             │
│                                                                      │
│  ┌────────────┐    ┌──────────────┐    ┌────────────────────────┐   │
│  │  Source    │───▶│   Matcher    │───▶│ Renderer (virt_text)   │   │
│  │ items / cb │    │ fuzzy + sort │    │ paints into ui.bufs.cmd│   │
│  └────────────┘    └──────────────┘    └────────────────────────┘   │
│        ▲                  ▲                       ▲                  │
│        │ async            │ coroutine             │ extmarks         │
│        │ uv.spawn         │ + querytick           │ on prompt line   │
│        │                  │                       │                  │
│  ┌─────┴──────────────────┴───────────────────────┴──────────────┐  │
│  │                  Controller (event loop)                       │  │
│  │   key dispatch · query state · current_ind · choose / stop    │  │
│  └────────────────────────────────────────────────────────────────┘  │
╰──────────────────────────────────────────────────────────────────────╯
```

Borrowed directly from `mini.pick` (proven design):

| mini.pick concept    | odif equivalent                                   |
|----------------------|---------------------------------------------------|
| picker object        | `state` table created by `M.start`                |
| `query` as `char[]`  | same — caret-aware editing                        |
| `querytick`          | same — abort stale match coroutines               |
| `poke_picker_throttle` | yield every ~10 ms inside match loop            |
| `set_items_from_cli` | wrap `vim.uv.spawn` for `rg --files` etc.         |
| `source.choose`      | same contract: truthy ⇒ keep open, falsy ⇒ close  |

Removed / changed:

| mini.pick                 | odif                                              |
|---------------------------|---------------------------------------------------|
| floating window (SW)      | **none** — uses `ui.wins.cmd`                     |
| `show` callback           | replaced by `format_item(item) -> string`         |
| preview / info views      | removed in v0                                     |
| marked items              | removed in v0                                     |
| `getcharstr` blocking loop| **`vim.on_key` + cmdline mappings** (non-blocking)|

---

## 4. UX spec (fido-horizontal)

```
┌ cmd window (ui.wins.cmd) ───────────────────────────────────────────┐
│ odif❭ src/ut▏ {[utils.lua] ut_helpers.ts | tests/utils_spec.lua | …}│
└─────────────────────────────────────────────────────────────────────┘
   prompt        user text^      virt_text — current in [ ], rest after
                                 truncated with `…` if it overflows width
```

- **Single line** by default. Candidates separated by ` │ ` (configurable).
- The **current candidate** is wrapped in `[ ]` and highlighted
  (`OdifCurrent` → `PmenuSel`).
- Other matches use `OdifMatch` → `Pmenu`.
- Truncation indicators `…` on either side when overflow.
- If `opts.layout = 'multiline'` (later): wrap into N lines using the
  existing cmdline expansion mechanism (`cfg.height = math.max(...)`).

### Keys

| Key                  | Action                                            |
|----------------------|---------------------------------------------------|
| printable            | append to query, retrigger match                  |
| `<BS>`               | delete char left of caret                         |
| `<C-u>`              | clear query                                       |
| `<C-w>`              | delete word left                                  |
| `<Left>` / `<Right>` | move caret in query                               |
| `<C-n>` / `<Down>`   | next match                                        |
| `<C-p>` / `<Up>`     | prev match                                        |
| `<C-,>` / `<C-.>`    | prev / next match (Emacs fido parity)             |
| `<C-s>` / `<C-r>`    | next / prev (Emacs incremental search parity)     |
| `<Home>` / `<End>`   | first / last match                                |
| `<CR>`               | choose current match                              |
| `<C-j>` / `<M-j>`    | accept literal query (`source.choose_literal`)    |
| `<C-d>`              | delete-suggestion / use literal (fido `C-d`)      |
| `<Esc>` / `<C-c>`    | abort, restore cmdline                            |
| `<Tab>`              | (later) toggle preview                            |

---

## 5. Module layout

```
odif/
├── lua/odif/
│   ├── init.lua          -- public API: start(), stop(), setup(), registry
│   ├── controller.lua    -- event loop, key dispatch, lifecycle
│   ├── render.lua        -- virt_text painter on ui.bufs.cmd
│   ├── match.lua         -- fuzzy matcher + bucket sort + querytick
│   ├── source.lua        -- source helpers + builtin sources
│   │   builtin/
│   │     files.lua       -- rg --files / fd / fallback
│   │     buffers.lua
│   │     help.lua
│   │     lsp_symbols.lua
│   ├── ui2_bridge.lua    -- thin wrapper: get cmd win/buf, hook FileType
│   └── util.lua
├── plugin/odif.lua       -- :Odif user command + default mappings
├── doc/odif.txt          -- vimdoc
├── tests/                -- mini.test or plenary
└── README.md
```

---

## 6. Public API (v0)

```lua
require('odif').setup({
  prompt   = 'odif❭ ',
  separator= ' │ ',
  hl = {
    prompt   = 'Question',
    match    = 'Pmenu',
    current  = 'PmenuSel',
    overflow = 'Comment',
  },
  delay = { busy = 80, async = 10 },  -- ms
  mappings = { … },                   -- override/add
})

require('odif').start({
  source = {
    name  = 'files',
    items = function(set)             -- async push
      set(vim.fn.systemlist('fd .'))
    end,
    format_item   = function(it) return it end,           -- string projection
    choose        = function(it) vim.cmd.edit(it) end,
    choose_literal= function(text) vim.cmd.edit(text) end,
  },
})

-- :Odif files
-- :Odif buffers
-- :Odif <name>      -- looks up odif.registry[name]
```

Runtime helpers (mirroring mini.pick):

```lua
odif.is_active()            -- bool
odif.get_query()            -- string
odif.get_current()           -- current item or nil
odif.set_items(arr)         -- async
odif.set_items_from_cli(cmd)-- spawn + stream
odif.stop()
```

---

## 7. Implementation phases

### Phase 0 — scaffolding
- Repo skeleton, `setup()`, `:Odif`, basic `init.lua`, vimdoc stub.
- Health check that warns if `vim._core.ui2` isn't `enable()`d.

### Phase 1 — cmdline bridge (the risky bit, do this first)
- `ui2_bridge.attach()`: ensure `ui2.enable({ enable = true })` is called,
  then grab `ui.bufs.cmd` / `ui.wins.cmd`.
- Open a prompt with `vim.fn.input({prompt = opts.prompt, …})` — but
  intercept keys via a transient `cmdline` mapping table so we never block
  on `getcharstr`.
- Render hello-world virt_text on the prompt line via
  `nvim_buf_set_extmark(ui.bufs.cmd, ns, row, col, { virt_text = …, virt_text_pos = 'inline' })`.
- Verify ui2 doesn't clobber our extmark on every `cmdline_show`
  (it might — `set_text` rewrites the buffer line). If it does, hook the
  same handler chain or repaint after each `cmdline_pos`.

> **Risk / Spike**: ui2.cmdline replaces buffer lines on every keystroke
> (`set_text` line ~70), which clears extmarks on the affected lines. We
> handle this **without** opening any new window. Options, in order of
> preference:
> 1. **Wrap `vim._core.ui2.cmdline.cmdline_show`** (monkey-patch the module
>    table) to call our repaint hook *after* it runs `set_text`. This is
>    the cleanest path since the module is a singleton table.
> 2. Subscribe to `nvim_buf_attach(ui.bufs.cmd, false, { on_lines = … })`
>    and reapply extmarks on every change.
> 3. Drive everything through `vim.fn.input()` / cmdline mappings so ui2
>    naturally repaints the prompt+text, and we add the candidate strip as
>    a `virt_text` extmark with `right_align`/`eol` that survives because
>    extmarks placed *after* the text aren't touched by `set_text`.
>
> Spike on day 1. Under no circumstance do we fall back to a floating
> window — if all three fail, we hide `ui.wins.cmd` and write directly to
> `ui.bufs.cmd` ourselves while the picker is active, restoring ui2's
> handlers on stop.

### Phase 2 — query state + sync matcher
- `query`/`caret`/`querytick` model from mini.pick.
- Synchronous fuzzy match over a static array (`{'foo','bar',…}`).
- Render strip of matches with current highlighted.

### Phase 3 — async items + matcher
- Coroutine-based `match.run(stritems, query, qt, on_done)`; yield via
  `vim.schedule` every `delay.async` ms.
- `source.set_items_from_cli` using `vim.uv.spawn` + line-buffered pipe,
  cleanup on stop.
- Busy indicator: change prompt highlight after `delay.busy` ms.

### Phase 4 — builtin sources
- `files` (rg --files → fd → find), `buffers`, `help`, `oldfiles`.
- `lsp_symbols` (sync, uses `vim.lsp.buf_request_all`).

### Phase 5 — polish
- `<C-d>` fido semantics, `choose_literal`, `:Odif resume`.
- Configurable separator, multiline overflow, vertical fallback flag.
- `vim.ui.select` opt-in.

### Phase 6 — tests + docs
- `tests/`: matcher determinism, querytick aborts, render snapshots.
- `doc/odif.txt`, README with gif.

---

## 8. Open questions to resolve before coding

1. **Can we reuse `ui.bufs.cmd` safely?** Spike Phase 1. The answer must be
   yes — there is no floating-window fallback. If extmark-on-cmdline can't
   carry the candidate strip, the fallback is to write the strip directly
   into `ui.bufs.cmd` text (after the user's input, on the same line),
   *not* to open a new window.
2. **How to capture keys without `getcharstr`?** Two options:
   - (a) `vim.on_key` callback while picker active + swallow via
     `nvim_input('')` — fragile.
   - (b) Buffer-local mappings on `ui.bufs.cmd` for every printable + special
     key, set in a `FileType cmd` autocmd when picker is active, removed on
     stop. **Preferred** — explicit, debuggable.
3. **Cursor visibility** during picker: hide via `guicursor` blend trick (à
   la mini.pick) or rely on the cmd window's own cursor. Test both.
4. **Compatibility**: ui2 is experimental and lives at
   `vim._core.ui2` (note the underscore). Pin doc to v0.12.2; gate `setup()`
   on `vim.fn.has('nvim-0.12') == 1` and `pcall(require, 'vim._core.ui2')`.
5. **Naming**: `odif` short and unique, or `fido.nvim` (collides with
   existing repos)? Recommend `odif`.

---

## 9. Success criteria for v0 (MVP)

- `:Odif files` over a 50k-file repo:
  - first paint < 50 ms,
  - keystroke-to-render < 20 ms median,
  - never blocks for > 16 ms in a single tick.
- Picker visually lives in the cmdline area (no extra floating window).
- Works with `cmdheight=0`, `cmdheight=1`, and `cmdheight=2`.
- `<CR>` opens file; `<C-c>` aborts cleanly and restores prior cmdline state.
- Survives `:tabnew`, `:resize`, and `VimResized` during an active session.

---

## 10. References

- `runtime/lua/vim/_core/ui2.lua` (v0.12.2) — ui2 enable, window/buffer management.
- `runtime/lua/vim/_core/ui2/cmdline.lua` (v0.12.2) — `cmdline_show`, `set_text`, prompt highlighting.
- `nvim-mini/mini.pick` — picker-object pattern, querytick, async via coroutine.
- Emacs `fido-mode` (Xah Lee, MasteringEmacs) — UX semantics, key bindings (`C-d`, `M-j`, `C-,`/`C-.`, `C-s`/`C-r`).
