-- Saved-source compiler tools. HLS remains the separate live language server.
local M = {}
local options = { python = 'python' }

local function project_root()
  local file = vim.api.nvim_buf_get_name(0)
  return assert(vim.fs.root(file ~= '' and file or vim.fn.getcwd(), { 'fp-game.json', 'cabal.project' }), 'Open a game or foundation project first')
end

local function diagnostics(text)
  local entries = {}
  for filename, line, column, severity in text:gmatch('([^\r\n]+%.hs):(%d+):(%d+):%s*(%a+):') do
    entries[#entries + 1] = { filename = filename, lnum = tonumber(line), col = tonumber(column), type = severity == 'error' and 'E' or 'W', text = severity .. ': see compiler output' }
  end
  vim.fn.setqflist(entries, 'r')
end

function M.run(action, symbol, callback, show)
  local root = project_root()
  local command = { options.python, root .. '/tools/fp_game.py', action, '--project', root, '--json' }
  if action ~= 'doctor' then
    local file = vim.api.nvim_buf_get_name(0)
    assert(file:match('%.hs$'), 'Open a saved Haskell file first')
    command[#command + 1] = file
  end
  if action == 'context' then
    command[#command + 1] = '--symbol'
    command[#command + 1] = symbol or vim.fn.expand('<cword>')
  end
  vim.system(command, { cwd = root, text = true }, function(process)
    vim.schedule(function()
      local ok, result = pcall(vim.json.decode, process.stdout or '')
      if not ok then result = { exit_code = process.code, stderr = process.stderr, status = 'invalid-cli-output' } end
      if action == 'check' then diagnostics(result.stderr or '') end
      if show then
        local buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(vim.inspect(result), '\n', { plain = true }))
        vim.cmd('botright split')
        vim.api.nvim_win_set_buf(0, buffer)
        vim.bo[buffer].modifiable = false
      end
      if callback then callback(result) end
    end)
  end)
end

function M.start_hls()
  local root = project_root()
  return vim.lsp.start({ name = 'hls', cmd = { 'haskell-language-server-wrapper', '--lsp' },
    root_dir = root, cmd_env = { CABAL_CONFIG = root .. '/build.config' } })
end

function M.setup(configuration)
  options = vim.tbl_extend('force', options, configuration or {})
  for action, name in pairs({ doctor = 'Doctor', check = 'Check', inspect = 'Inspect', context = 'Context' }) do
    local command_action = action
    vim.api.nvim_create_user_command('FPG' .. name, function(args)
      M.run(command_action, args.args ~= '' and args.args or nil, nil, true)
    end, { nargs = action == 'context' and '?' or 0, force = true })
  end
  vim.api.nvim_create_user_command('FPGHls', M.start_hls, { force = true })
end

return M
