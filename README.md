# odif

A **fido-horizontal** picker for Neovim, rendered entirely inside the
experimental `vim._core.ui2` cmdline buffer. **No floating windows.**

```
odif❭ src/co  {init.lua │ [controller.lua] │ render.lua │ match.lua │ …}
```

> Status: **early v0 / Phase 1** — render + sync match work end-to-end.
> See [`PLAN.md`](./PLAN.md) for the roadmap.

## Requirements

- Neovim **0.12+** (uses `vim._core.ui2`, which is experimental and lives
  at an underscored path on purpose).

## Try it

```vim
:set rtp+=/path/to/odif
:lua require('odif').setup()
:Odif buffers      " or :Odif files
```

Default keys (fido parity):

| Key                          | Action                          |
| ---------------------------- | ------------------------------- |
| printable                    | extend query                    |
| `<BS>`                       | delete char                     |
| `<C-u>` / `<C-w>`            | clear / delete-word             |
| `<C-n>` `<Down>` `<Right>` `<C-s>` | next match                |
| `<C-p>` `<Up>`   `<Left>`  `<C-r>` | prev match                |
| `<Home>` / `<End>`           | first / last match              |
| `<CR>`                       | choose current match            |
| `<C-j>` / `<C-d>`            | accept literal query (fido)     |
| `<Esc>` / `<C-c>`            | abort                           |

## Tests

```sh
nvim --headless --clean -u NONE -l tests/smoke.lua
nvim --headless --clean -u NONE -l tests/ui.lua && cat /tmp/odif-ui-test.log
nvim --headless --clean -u NONE -l tests/controller_dispatch.lua
```

## Layout

```
lua/odif/
  init.lua        public API + registry
  controller.lua  event loop (getcharstr); key→action dispatch
  render.lua      paints prompt + virt_text strip into ui.bufs.cmd
  match.lua       sync fuzzy matcher (window-minimising, bucket sort)
  ui2_bridge.lua  thin handle on ui.bufs.cmd / ui.wins.cmd
  source/
    buffers.lua
    files.lua     rg → fd → find
plugin/odif.lua   :Odif user command
tests/            smoke.lua, ui.lua, controller_dispatch.lua
```
