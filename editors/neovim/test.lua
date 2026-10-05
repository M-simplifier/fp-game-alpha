local root = assert(os.getenv('FP_GAME_EDITOR_PROJECT'))
local module = dofile(assert(os.getenv('FP_GAME_NVIM_MODULE')))
module.setup()
local source = root .. '/src/EditorProbe.hs'
vim.fn.writefile({ '-- Helpers similar to module Prelude', 'module EditorProbe where', 'twice :: Integer -> Integer', 'twice x = x + x' }, source)
vim.cmd.edit(vim.fn.fnameescape(source))

local calls = {}
local system = vim.system
vim.system = function(command, options, callback)
  calls[#calls + 1] = { command = command, options = options }
  return system(command, options, callback)
end

local function query(action, symbol)
  local done, result = false, nil
  module.run(action, symbol, function(value) result = value; done = true end, false)
  assert(vim.wait(180000, function() return done end, 50), 'Compiler query timeout')
  local selected_file = vim.api.nvim_buf_get_name(0)
  local cli_root = assert(vim.fs.root(selected_file, { 'fp-game.json', 'cabal.project' }))
  local native = action == 'doctor' or action == 'check'
  local entrypoint = native and (cli_root .. '/.build/tools/fp-game' .. (vim.fn.has('win32') == 1 and '.exe' or ''))
    or (cli_root .. '/tools/inspect_haskell.py')
  local expected = native and { entrypoint } or { 'python', entrypoint }
  for _, value in ipairs({ action, '--project', cli_root, '--json' }) do expected[#expected + 1] = value end
  if action ~= 'doctor' then expected[#expected + 1] = selected_file end
  if action == 'context' then expected[#expected + 1] = '--symbol'; expected[#expected + 1] = symbol end
  assert(vim.deep_equal(calls[#calls].command, expected), vim.inspect(calls[#calls]))
  assert(calls[#calls].options.cwd == cli_root)
  local compiler = os.getenv('FP_GAME_EDITOR_COMPILER')
  if native and compiler then
    local function normalize(value)
      value = vim.fs.normalize(value)
      return vim.fn.has('win32') == 1 and value:lower() or value
    end
    local selected = action == 'doctor' and result.compiler_selection.path or result.command[1]
    assert(normalize(selected) == normalize(compiler), vim.inspect(result))
  end
  return result
end

local doctor = query('doctor')
assert(doctor.exit_code == 0 and doctor.implementation == 'haskell', vim.inspect(doctor))
local checked = query('check')
assert(checked.exit_code == 0, vim.inspect(checked))
local context = query('context', 'twice')
assert(context.exit_code == 0 and context.module == 'EditorProbe', vim.inspect(context))
assert(context.stdout:find('Integer -> Integer', 1, true))
local structure = query('inspect')
assert(structure.exit_code == 0 and structure.module == 'EditorProbe')
vim.fn.writefile({ 'module EditorProbe where', 'bad :: Integer', 'bad = True' }, source)
local failed = query('check')
assert(failed.exit_code ~= 0 and #vim.fn.getqflist() > 0)
vim.fn.writefile({ 'module EditorProbe where', 'import Data.List (sort)', 'twice :: Integer -> Integer', 'twice x = x + x' }, source)
local warning = query('check')
assert(warning.exit_code == 0 and #vim.fn.getqflist() > 0, vim.inspect(warning))
for _, entry in ipairs(vim.fn.getqflist()) do assert(entry.type == 'W', vim.inspect(entry)) end
local checks = { 'actual-headless-neovim', 'native-doctor-and-check', 'inspector-command-selection', 'module-and-type', 'saved-source-compiler-error', 'quickfix-diagnostics', 'successful-native-warning-clears-errors' }
if os.getenv('FP_GAME_TEST_HLS') == '1' then
  vim.fn.writefile({ 'module EditorProbe where', 'twice :: Integer -> Integer', 'twice x = x + x' }, source)
  vim.cmd('edit!')
  local identifier = assert(module.start_hls(), 'HLS did not start')
  assert(vim.wait(180000, function()
    local client = vim.lsp.get_client_by_id(identifier)
    return client and client.initialized
  end, 100), 'HLS initialization timeout')
  local client = assert(vim.lsp.get_client_by_id(identifier))
  -- Initialization is earlier than project loading. Retry hover within a bound.
  local hover
  assert(vim.wait(180000, function()
    local result = client:request_sync('textDocument/hover', { textDocument = { uri = vim.uri_from_fname(source) }, position = { line = 1, character = 2 } }, 1000, 0)
    if result and result.result and result.result.contents then hover = result.result; return true end
    return false
  end, 250), 'HLS hover timeout')
  assert(vim.inspect(hover):find('Integer', 1, true), vim.inspect(hover))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'module EditorProbe where', 'bad :: Integer', 'bad = True' })
  vim.cmd('write')
  assert(vim.wait(60000, function() return #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.ERROR }) > 0 end, 100), 'HLS diagnostic timeout')
  checks[#checks + 1] = 'live-hls-initialization-hover-and-diagnostics'
  client:stop()
end
vim.fn.writefile({ vim.json.encode({ status = 'pass', checks = checks, neovim = vim.version() }) }, root .. '/neovim-test-result.json')
vim.cmd('qa!')
