--- Builtin source: document symbols of the current buffer via LSP.
--- Items are SymbolInformation/DocumentSymbol records. Choose jumps to
--- the symbol's location in the source buffer.

local KIND = vim.lsp.protocol.SymbolKind or {}
local KIND_NAME = {} -- numeric kind → display name
for k, v in pairs(KIND) do
  if type(v) == 'number' then KIND_NAME[v] = k end
end

local function flatten(symbols, parent, out)
  for _, s in ipairs(symbols or {}) do
    local name = parent and (parent .. '.' .. s.name) or s.name
    out[#out + 1] = {
      name = name,
      kind = KIND_NAME[s.kind] or '?',
      range = s.range or (s.location and s.location.range),
      uri = s.location and s.location.uri,
    }
    if s.children then flatten(s.children, name, out) end
  end
  return out
end

return {
  name = 'lsp_symbols',
  items = function(set)
    local bufnr = vim.api.nvim_get_current_buf()
    local clients = vim.lsp.get_clients({ bufnr = bufnr, method = 'textDocument/documentSymbol' })
    if #clients == 0 then
      vim.notify('[odif] no LSP client supports documentSymbol', vim.log.levels.WARN)
      set({})
      return
    end

    local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
    set({})
    vim.schedule(function()
      vim.lsp.buf_request_all(bufnr, 'textDocument/documentSymbol', params, function(results)
        local items = {}
        for _, res in pairs(results or {}) do
          if res.result then flatten(res.result, nil, items) end
        end
        require('odif').set_items(items)
      end)
    end)
  end,
  format_item = function(it) return ('[%s] %s'):format(it.kind, it.name) end,
  choose = function(it)
    if not it or not it.range then return end
    local row = it.range.start.line + 1
    local col = it.range.start.character
    if it.uri then vim.cmd.edit(vim.uri_to_fname(it.uri)) end
    pcall(vim.api.nvim_win_set_cursor, 0, { row, col })
    vim.cmd('normal! zz')
  end,
}
