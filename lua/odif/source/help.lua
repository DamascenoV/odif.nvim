--- Builtin source: all `:help` tags collected from `doc/tags` files
--- under runtimepath. `<CR>` opens the help page; `<C-j>`/literal opens
--- whatever the user typed verbatim via `:help <text>`.

return {
  name = 'help',
  prompt = 'Help topic: ',
  items = function(set)
    local seen, out = {}, {}
    for _, tagfile in ipairs(vim.api.nvim_get_runtime_file('doc/tags', true)) do
      local fh = io.open(tagfile, 'r')
      if fh then
        for line in fh:lines() do
          -- Format: <tag>\t<file>\t<search>
          local tag = line:match('^([^\t]+)')
          if tag and not seen[tag] then
            seen[tag] = true
            out[#out + 1] = tag
          end
        end
        fh:close()
      end
    end
    table.sort(out)
    set(out)
  end,
  format_item = function(it) return it end,
  choose = function(it)
    if it then vim.cmd('help ' .. vim.fn.escape(it, ' \\|"')) end
  end,
  choose_literal = function(text)
    if text and text ~= '' then vim.cmd('help ' .. vim.fn.escape(text, ' \\|"')) end
  end,
}
