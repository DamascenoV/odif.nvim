# odif

A **fido-horizontal** picker for Neovim, rendered entirely inside the
experimental `vim._core.ui2` cmdline buffer. **No floating windows.**

```
Find file: src/co  init.lua │ controller.lua │ render.lua │ match.lua  3/127
```

The picker is the cmdline. Candidates wrap onto a second row (configurable
via `max_height`). The current match is highlighted; `<CR>` picks it.
`<Tab>` previews by temporarily replacing the target window's buffer.

See [`:help odif`](./doc/odif.txt) for the full manual.

## Requirements

- Neovim **0.12+** (uses `vim._core.ui2`, which is experimental and lives
  at an underscored path on purpose).
- Optional: `rg` (for `files` and required by `grep`), `fd`, or `find`.

## Quickstart

```lua
vim.opt.runtimepath:prepend('/path/to/odif')

-- ui2 is experimental; you must enable it.
require('vim._core.ui2').enable({})

require('odif').setup({})

-- Optional: replace vim.ui.select
vim.ui.select = require('odif').ui_select

vim.keymap.set('n', '<leader>ff', function() require('odif').start({ source = require('odif').registry.files }) end)
vim.keymap.set('n', '<leader>fg', function() require('odif').start({ source = require('odif').registry.grep  }) end)
vim.keymap.set('n', '<leader>fb', function() require('odif').start({ source = require('odif').registry.buffers }) end)
```

Or use the `:Odif` command: `:Odif files`, `:Odif grep`, `:Odif resume`, …

## Built-in sources

| Name          | Prompt              | Notes                                    |
| ------------- | ------------------- | ---------------------------------------- |
| `files`       | `Find file: `       | streams `rg --files` → `fd` → `find`    |
| `buffers`     | `Switch to buffer: ` | listed, loaded buffers                  |
| `oldfiles`    | `Recent file: `     | `v:oldfiles` filtered to readable files |
| `help`        | `Help topic: `      | all `doc/tags` entries                  |
| `grep`        | `Grep: `            | live `rg`, debounced 120 ms             |
| `lsp_symbols` | `Symbol: `          | document symbols of the current buffer  |

## Default keys (fido parity)

| Key                                | Action                          |
| ---------------------------------- | ------------------------------- |
| printable                          | extend query                    |
| `<BS>` / `<Del>`                   | delete char                     |
| `<C-u>` / `<C-w>`                  | clear / delete-word             |
| `<Left>` / `<Right>`               | move caret                      |
| `<Home>` / `<End>`                 | caret to start / end            |
| `<C-n>` `<Down>` `<C-s>`           | next match                      |
| `<C-p>` `<Up>` `<C-r>`             | prev match                      |
| `<C-Home>` / `<C-End>`             | first / last match              |
| `<CR>`                             | choose current match            |
| `<C-q>`                            | send current results to quickfix |
| `<C-o>`                            | filter current results by glob  |
| `<C-j>` / `<C-d>`                  | accept literal query            |
| `<Tab>`                            | toggle preview                  |
| `<Esc>` / `<C-c>`                  | abort                           |

All bindings are configurable via `config.mappings`; see `:help odif-config`.

While the picker is open, press `<C-o>` and enter a glob such as `*.json`
to filter the current results. Submit an empty glob to clear it.

Built-in `files` and `grep` can also be constrained up-front by extension/glob:

```lua
require('odif').setup({
  files = { filetypes = { 'lua', 'md' }, glob = 'lua/**' },
  grep = { filetypes = 'lua', min_query = 2 },
})
```

## Tests

```sh
./tests/run.sh
```

## Layout

```
lua/odif/
  init.lua         public API + registry + async/streaming entry points
  controller.lua   event loop (getcharstr); key→action dispatch
  render.lua       paints prompt + virt_text strip into ui.bufs.cmd
  match.lua        sync + async fuzzy matcher
  spawn.lua        line-buffered uv.spawn wrapper
  ui2_bridge.lua   acquire/release of ui.bufs.cmd / ui.wins.cmd
  source/          buffers, files, oldfiles, help, grep, lsp_symbols
plugin/odif.lua    :Odif user command
doc/odif.txt       vimdoc help
tests/             run.sh + per-module tests
```
