if vim.g.loaded_odif or vim.g.odif_disable then return end
vim.g.loaded_odif = 1

if vim.fn.has('nvim-0.12') ~= 1 then
  vim.notify('[odif] requires Neovim 0.12+', vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command('Odif', function(opts)
  local odif = require('odif')
  if not odif.registry.buffers then odif.setup() end
  local name = opts.fargs[1] or 'buffers'
  if name == 'resume' then
    odif.resume()
    return
  end
  local source = odif.registry[name]
  if not source then
    vim.notify(('[odif] no source named %q'):format(name), vim.log.levels.ERROR)
    return
  end
  odif.start({ source = source })
end, {
  nargs = '?',
  complete = function()
    local out = vim.tbl_keys(require('odif').registry)
    out[#out + 1] = 'resume'
    return out
  end,
  desc = 'Open an odif picker (`:Odif resume` reopens the last one)',
})
