-- Saved-source compiler tools. HLS remains the separate live language server.
local M = {}
local options = { python = 'python' }

local function project_root()
  local file = vim.api.nvim_buf_get_name(0)
  return assert(vim.fs.root(file ~= '' and file or vim.fn.getcwd(), { 'fp-game.json', 'cabal.project' }), 'Open a game or foundation project first')
end

local function diagnostics(text, root)
  local entries = {}
  for filename, line, column, severity in text:gmatch('([^\r\n]+%.hs):(%d+):(%d+)%-?%d*:%s*(%a+):') do
    if severity == 'error' or severity == 'warning' then
      if not filename:match('^[/\\]') and not filename:match('^%a:[/\\]') then filename = root .. '/' .. filename end
      entries[#entries + 1] = { filename = filename, lnum = tonumber(line), col = tonumber(column), type = severity == 'error' and 'E' or 'W', text = severity .. ': see compiler output' }
    end
  end
  vim.fn.setqflist(entries, 'r')
end

function M.run(action, symbol, callback, show)
  local root = project_root()
  assert(action == 'doctor' or action == 'check' or action == 'inspect' or action == 'context', 'Unknown FP Game command')
  local native = action == 'doctor' or action == 'check'
  local entrypoint = native and (root .. '/.build/tools/fp-game' .. (vim.fn.has('win32') == 1 and '.exe' or ''))
    or (root .. '/tools/inspect_haskell.py')
  assert(vim.fn.filereadable(entrypoint) == 1, native
    and 'The project-local native fp-game is missing. Run tools/bootstrap-fp-game.sh (Windows: tools/bootstrap-fp-game.ps1) first'
    or 'The project-local tools/inspect_haskell.py is missing')
  local command = { entrypoint, action, '--project', root, '--json' }
  if not native then table.insert(command, 1, options.python) end
  if action ~= 'doctor' then
    local file = vim.api.nvim_buf_get_name(0)
    assert(file:match('%.hs$') and vim.fn.filereadable(file) == 1 and not vim.bo.modified, 'Save and select a Haskell file first')
    command[#command + 1] = file
  end
  if action == 'context' then
    command[#command + 1] = '--symbol'
    local binding = symbol or vim.fn.expand('<cword>')
    assert(binding ~= '', 'Place the cursor on a binding, or pass a symbol')
    command[#command + 1] = binding
  end
  vim.system(command, { cwd = root, text = true }, function(process)
    vim.schedule(function()
      local ok, result = pcall(vim.json.decode, process.stdout or '')
      if not ok or type(result) ~= 'table' or type(result.exit_code) ~= 'number' or result.exit_code ~= process.code then
        result = { exit_code = process.code ~= 0 and process.code or 1,
          stderr = 'Invalid CLI result or CLI/process outcome mismatch.\n' .. (process.stderr or ''), status = 'invalid-cli-output' }
      end
      if action == 'check' then diagnostics(result.stderr or '', root) end
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
