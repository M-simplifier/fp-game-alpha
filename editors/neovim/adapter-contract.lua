-- Adapter unit contract, runnable with Lua or texlua without an editor/compiler.
-- test.lua separately exercises installed Neovim, GHC/GHCi and optional HLS.
local adapter = (arg[0]:match('^(.*[/\\])') or '') .. 'fp-game.lua'

local function check_platform(windows)
  local root = windows and 'C:\\Editor game & 日本語' or '/Editor game & 日本語'
  local source = root .. '/src/EditorProbe.hs'
  local binary = root .. '/.build/tools/fp-game' .. (windows and '.exe' or '')
  local inspector = root .. '/tools/inspect_haskell.py'
  local python = root .. '/Python tools/python' .. (windows and '.exe' or '')
  local files = { [source] = true, [binary] = true, [inspector] = true }
  local current_file = source
  local calls, registered, quickfix = {}, {}, {}
  local next_result = { exit_code = 0, stdout = '', stderr = '' }
  local process_code, valid_json = 0, true
  vim = {
    bo = { modified = false },
    api = {
      nvim_buf_get_name = function() return current_file end,
      nvim_create_user_command = function(name, callback) registered[name] = callback end,
    },
    fs = { root = function(file) assert(file == current_file or file == root); return root end },
    fn = {
      getcwd = function() return root end,
      has = function(feature) assert(feature == 'win32'); return windows and 1 or 0 end,
      filereadable = function(file) return files[file] and 1 or 0 end,
      expand = function(word) assert(word == '<cword>'); return 'twice' end,
      setqflist = function(entries, operation) assert(operation == 'r'); quickfix = entries end,
    },
    tbl_extend = function(_, old, new)
      local result = {}; for key, value in pairs(old) do result[key] = value end
      for key, value in pairs(new) do result[key] = value end; return result
    end,
    json = { decode = function(text) assert(valid_json and text == 'CLI JSON', 'invalid JSON'); return next_result end },
    schedule = function(callback) callback() end,
    system = function(command, options, callback)
      calls[#calls + 1] = { command = command, options = options }
      callback({ code = process_code, stdout = 'CLI JSON', stderr = '' })
    end,
  }
  local module = dofile(adapter)
  module.setup({ python = python })
  for _, name in ipairs({ 'Doctor', 'Check', 'Inspect', 'Context', 'Hls' }) do assert(registered['FPG' .. name]) end
  local function run(action, symbol)
    local result
    module.run(action, symbol, function(value) result = value end, false)
    return result
  end
  local function expect_command(action, trailing)
    local native = action == 'doctor' or action == 'check'
    local expected = native and { binary } or { python, inspector }
    for _, value in ipairs({ action, '--project', root, '--json' }) do expected[#expected + 1] = value end
    for _, value in ipairs(trailing or {}) do expected[#expected + 1] = value end
    local call = calls[#calls]
    assert(#call.command == #expected)
    for index, value in ipairs(expected) do assert(call.command[index] == value, action .. ' argument ' .. index) end
    assert(call.options.cwd == root and call.options.text == true)
    -- vim.system receives an argument array, never a shell command string.
  end
  current_file = ''
  run('doctor'); expect_command('doctor')
  current_file = source
  next_result = { exit_code = 0, stdout = '', stderr = source .. ':4:7-12: warning: unused binding\n\n' }
  run('check'); expect_command('check', { source })
  assert(#quickfix == 1 and quickfix[1].filename == source and quickfix[1].type == 'W')
  assert(quickfix[1].lnum == 4 and quickfix[1].col == 7)
  next_result = { exit_code = 1, stdout = '', stderr = 'src/EditorProbe.hs:3:7: error: type mismatch\n\n' }
  process_code = 1
  run('check')
  assert(#quickfix == 1 and quickfix[1].filename == source and quickfix[1].type == 'E')
  next_result = { exit_code = 0, stdout = '', stderr = '' }; process_code = 0
  run('check'); assert(#quickfix == 0)
  run('inspect'); expect_command('inspect', { source })
  run('context', 'twice'); expect_command('context', { source, '--symbol', 'twice' })
  run('context'); expect_command('context', { source, '--symbol', 'twice' })
  local function refuses(action, pattern)
    local count = #calls
    local ok, error = pcall(run, action)
    assert(not ok and tostring(error):match(pattern), tostring(error))
    assert(#calls == count, 'refusals must not execute fallback commands')
  end
  vim.bo.modified = true
  for _, action in ipairs({ 'check', 'inspect', 'context' }) do refuses(action, 'Save and select') end
  vim.bo.modified = false; files[source] = nil
  refuses('check', 'Save and select'); files[source] = true
  files[binary] = nil
  for _, action in ipairs({ 'doctor', 'check' }) do refuses(action, 'bootstrap%-fp%-game') end
  run('inspect'); expect_command('inspect', { source })
  files[binary] = true; files[inspector] = nil
  run('doctor'); expect_command('doctor')
  run('check'); expect_command('check', { source })
  for _, action in ipairs({ 'inspect', 'context' }) do refuses(action, 'inspect_haskell%.py is missing') end
  files[inspector] = true
  next_result = { exit_code = 1, stderr = '' }
  assert(run('check').status == 'invalid-cli-output')
  assert(run('check').exit_code ~= 0)
  valid_json = false
  assert(run('check').status == 'invalid-cli-output')
  print((windows and 'win32' or 'linux') .. ': native/inspector routes, saved-source refusals, JSON outcomes, error/warning diagnostics passed')
end

check_platform(false)
check_platform(true)
