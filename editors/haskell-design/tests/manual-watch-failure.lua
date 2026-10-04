-- Actual plugin Lua with deterministic Vim/luv and RPC boundaries.
-- Run from the package directory: lua tests/manual-watch-failure.lua (or texlua).
-- Fault-injection unit coverage, not real Neovim or OS-watch qualification.
local badges, notices, requests, handles = {}, {}, {}, {}
local mode, refreshed = 'ok', 0
local rendered = {}
local function noop() end
vim = {
  fs = { dirname = function(p) return p:match('^(.*)/') or '.' end,
    normalize = function(p) return p end, root = function() return '/game' end },
  uv = { fs_realpath = function(p) return p end, cwd = function() return '/game' end },
  api = { nvim_create_namespace = function() return 1 end,
    nvim_buf_is_valid = function() return true end,
    nvim_get_current_buf = function() return 1 end,
    nvim_buf_get_name = function(b) return '/game/' .. b .. '.hs' end,
    nvim_buf_get_changedtick = function() return 1 end,
    nvim_buf_get_lines = function() return { 'module A where', 'a = 1' } end,
    nvim_buf_clear_namespace = noop,
    nvim_buf_set_lines = function(_, _, _, _, lines) rendered[#rendered + 1] = table.concat(lines, '\n') end,
    nvim_buf_set_extmark = function(_, _, _, _, opts) badges[#badges + 1] = opts.virt_text[1][1] end,
    nvim_list_bufs = function() return {} end },
  bo = setmetatable({}, { __index = function() return { endofline = true } end }),
  fn = { has = function() return 0 end, stdpath = function() return '/cache' end,
    bufwinid = function() return -1 end },
  log = { levels = { INFO = 1, WARN = 2 } },
  notify = function(message) notices[#notices + 1] = message end,
  schedule_wrap = function(fn) return fn end,
  split = function(text)
    local lines = {}
    for line in (text .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = line end
    return lines
  end,
}
vim.uv.new_fs_event = function()
  if mode == 'allocate-nil' then return nil, 'EMFILE' end
  if mode == 'allocate-throw' then error('EMFILE') end
  local handle = { closed = 0, stopped = 0 }
  function handle:start(_, _, callback)
    self.callback = callback
    if mode == 'start-nil' then return nil, 'ENOSPC' end
    if mode == 'start-negative' then return -1 end
    if mode == 'start-throw' then error('ENOSPC') end
    return 0
  end
  function handle:close() self.closed = self.closed + 1 end
  function handle:stop() self.stopped = self.stopped + 1 end
  handles[#handles + 1] = handle
  return handle
end
local hd = dofile('lua/haskell-design/init.lua')
local function upvalue(fn, name, replacement)
  for i = 1, 100 do
    local key, value = debug.getupvalue(fn, i)
    if not key then break end
    if key == name then
      if replacement then debug.setupvalue(fn, i, replacement) end
      return value
    end
  end
  error('missing upvalue: ' .. name)
end
local analyse = upvalue(hd.verify, 'analyse')
local options = upvalue(analyse, 'options')
options.auto_verify = false
upvalue(analyse, 'request', function(payload, callback)
  requests[#requests + 1] = { payload = payload, callback = callback }
end)
hd.refresh = function() refreshed = refreshed + 1 end
hd.views[10] = { source = 1, expanded = {} }
local function proof(file)
  return { file = '/game/1.hs', status = 'pure', verified = true,
    module = 'A', header = 'module A where', imports = {}, declarations = {},
    verification = { dependencies = { file } }, issues = {} }
end
local function verify(file)
  analyse(1, true)
  local result = proof(file)
  requests[#requests].callback(result)
  return result
end
local function unknown(model)
  assert(not model.verified and not model.verification and model.status == 'unknown', 'stale proof survived')
end
for _, failure in ipairs({ 'allocate-nil', 'allocate-throw', 'start-nil', 'start-negative', 'start-throw' }) do
  mode = failure
  local before = #handles
  hd.models[2] = proof('/game/shared.hs')
  hd.tree_views[20] = { tree = { summary = { status = 'pure', total = 1 },
    children = { { summary = { status = 'pure', total = 1 }, children = {} } } }, render = noop }
  analyse(2, false)
  local stale_startup = requests[#requests]
  badges = {}; rendered = {}
  local model = verify('/game/' .. failure .. '.hs')
  unknown(model); unknown(hd.models[2])
  stale_startup.callback(proof('/game/shared.hs'))
  unknown(hd.models[2])
  assert(hd.tree_views[20].tree.children[1].summary.status == 'unknown', 'nested folder stayed Pure')
  assert(hd.tree_views[20].tree.summary.status == 'unknown', 'cached folder stayed Pure')
  assert(#model.issues == 1 and #notices > 0, 'failure was silent')
  for _, badge in ipairs(badges) do assert(not badge:find('Pure', 1, true), 'transient Pure badge') end
  for _, text in ipairs(rendered) do assert(not text:find('Pure', 1, true), 'transient Pure design') end
  assert(not hd.status(1):find('Pure', 1, true), 'statusline retained Pure')
  assert(not hd.views[10].model.verified, 'view/menu model retained verification')
  if #handles > before then assert(handles[#handles].closed == 1, 'failed handle not closed once') end
  analyse(1, false)
  assert(requests[#requests].payload.verification == nil, 'failed proof reused on refresh')
  local unverified = proof('/game/unused.hs')
  unverified.status = 'unknown'; unverified.verified = false; unverified.verification = nil
  requests[#requests].callback(unverified)
  mode = 'ok'
  assert(verify('/game/' .. failure .. '.hs').verified, 're-verification did not recover')
end
-- A live failure invalidates previous models/trees and cancels older RPC replies.
mode = 'ok'
verify('/game/runtime.hs')
local active = handles[#handles]
analyse(1, false)
local stale = requests[#requests]
local refresh_tree = upvalue(upvalue(analyse, 'refresh_trees'), 'refresh_tree')
refresh_tree(20)
local stale_tree = requests[#requests]
active.callback('EIO')
unknown(hd.models[1]); unknown(hd.models[2])
assert(active.closed == 1 and active.stopped == 1 and refreshed == 1)
assert(hd.tree_views[20].tree.summary.status == 'unknown')
stale.callback(proof('/game/runtime.hs'))
stale_tree.callback({ tree = { summary = { status = 'pure', total = 1 }, children = {} } })
assert(hd.tree_views[20].tree.summary.status == 'unknown', 'stale tree reply restored Pure')
unknown(hd.models[1])
active.callback('EIO')
assert(active.closed == 1, 'queued errors closed the same handle twice')
local count = #handles
assert(verify('/game/runtime.hs').verified and #handles == count + 1, 'dead watcher reused')
-- Healthy watches are reused; normal notifications still invalidate proofs.
count = #handles
assert(verify('/game/runtime.hs').verified and #handles == count)
handles[#handles].callback(nil)
unknown(hd.models[1]); assert(refreshed == 2)
-- Automatic mode delegates watcher/fallback handling to Node.
options.auto_verify = true; mode = 'allocate-throw'
assert(verify('/game/automatic.hs').verified and #handles == count)
print('Actual Lua manual watch fault injection: allocation/start failures, runtime errors, stale replies, UI invalidation, recovery, normal events, automatic isolation: PASS')
