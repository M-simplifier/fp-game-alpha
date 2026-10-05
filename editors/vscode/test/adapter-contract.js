// Adapter unit contract. Runs the real command registrations with controlled
// process results; test/index.js separately exercises an installed VSCode/GHC.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { EventEmitter } = require('node:events');

async function checkPlatform(platform) {
  const paths = platform === 'win32' ? path.win32 : path.posix;
  const root = platform === 'win32' ? 'C:\\Editor game & 日本語' : '/Editor game & 日本語';
  const source = paths.join(root, 'src', 'EditorProbe.hs');
  const binary = paths.join(root, '.build', 'tools', platform === 'win32' ? 'fp-game.exe' : 'fp-game');
  const inspector = paths.join(root, 'tools', 'inspect_haskell.py');
  const python = paths.join(root, 'Python tools', platform === 'win32' ? 'python.exe' : 'python');
  const files = new Set([paths.join(root, 'fp-game.json'), source, binary, inspector]);
  const realPaths = new Map();
  const registrations = new Map();
  const calls = [];
  let next = { exit_code: 0, stdout: '', stderr: '' };
  let processCode = 0;
  let entries = [];
  let pythonReads = 0;
  class Position {
    constructor(line, character) { this.line = line; this.character = character; }
    translate(line, character) { return new Position(this.line + line, this.character + character); }
  }
  class Range { constructor(start, end) { this.start = start; this.end = end; } }
  class Diagnostic { constructor(range, message, severity) { Object.assign(this, { range, message, severity }); } }
  const document = { uri: { fsPath: source }, isDirty: false,
    getWordRangeAtPosition: () => ({}), getText: () => 'twice' };
  const editor = { document, selection: { active: {} } };
  const vscode = {
    Position, Range, Diagnostic, DiagnosticSeverity: { Error: 0, Warning: 1 }, Uri: { file: file => file },
    workspace: { isTrusted: true, workspaceFolders: [{ uri: { fsPath: root } }],
      getConfiguration: key => { assert.equal(key, 'fpGame'); return { get: name => {
        assert.equal(name, 'python'); pythonReads++; return python;
      } }; } },
    window: { activeTextEditor: editor, createOutputChannel: () => ({ clear() {}, appendLine() {}, show() {} }) },
    languages: { createDiagnosticCollection: () => ({ clear() { entries = []; }, set(value) { entries = value; } }) },
    commands: { registerCommand: (name, callback) => { registrations.set(name, callback); return {}; } },
  };
  function spawn(executable, args, options) {
    calls.push({ executable, args: [...args], options });
    const child = new EventEmitter();
    child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
    child.stdout.setEncoding = child.stderr.setEncoding = encoding => assert.equal(encoding, 'utf8');
    child.kill = () => {};
    queueMicrotask(() => {
      child.stdout.emit('data', typeof next === 'string' ? next : JSON.stringify(next));
      child.emit('close', processCode);
    });
    return child;
  }
  const module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '..', 'extension.js'), 'utf8'), {
    module, process: { platform }, setTimeout, clearTimeout,
    require: name => ({ vscode, 'node:fs': { existsSync: file => files.has(file), realpathSync: file => realPaths.get(file) || file },
      'node:path': paths, 'node:child_process': { spawn } })[name],
  }, { filename: 'extension.js' });
  module.exports.activate({ subscriptions: [] });
  const run = (action, symbol) => registrations.get('fpGame.' + action)(symbol);
  const expectCommand = (action, argumentsAfterAction = []) => {
    const call = calls.at(-1);
    const native = action === 'doctor' || action === 'check';
    assert.equal(call.executable, native ? binary : python);
    assert.deepEqual(call.args, [...(native ? [] : [inspector]), action, '--project', root, '--json', ...argumentsAfterAction]);
    assert.equal(call.options.cwd, root);
    assert.equal(call.options.shell, false);
    assert.equal(call.options.windowsHide, true);
  };

  vscode.window.activeTextEditor = undefined;
  await run('doctor'); expectCommand('doctor');
  vscode.window.activeTextEditor = editor;
  next = { exit_code: 0, stdout: '', stderr: `${source}:4:7-12: warning: unused binding\n\n` };
  await run('check'); expectCommand('check', [source]);
  assert.equal(pythonReads, 0, 'native commands must not consult the Python setting');
  assert.equal(entries[0][0], source);
  assert.equal(entries[0][1][0].severity, vscode.DiagnosticSeverity.Warning);
  assert.equal(entries[0][1][0].range.start.line, 3);
  assert.equal(entries[0][1][0].range.start.character, 6);
  next = { exit_code: 1, stdout: '', stderr: 'src/EditorProbe.hs:3:7: error: type mismatch\n\n' };
  processCode = 1;
  await run('check');
  assert.equal(entries[0][0], source, 'relative compiler paths use the project root');
  assert.equal(entries[0][1][0].severity, vscode.DiagnosticSeverity.Error);
  next = { exit_code: 0, stdout: '', stderr: '' }; processCode = 0;
  await run('check'); assert.equal(entries.length, 0, 'successful clean checks clear stale errors');
  await run('inspect'); expectCommand('inspect', [source]);
  await run('context', 'twice'); expectCommand('context', [source, '--symbol', 'twice']);
  await run('context'); expectCommand('context', [source, '--symbol', 'twice']);
  assert.equal(pythonReads, 3);

  async function refuses(action, pattern) {
    const count = calls.length;
    await assert.rejects(run(action), pattern);
    assert.equal(calls.length, count, 'refusal must not execute a fallback');
  }
  document.isDirty = true;
  for (const action of ['check', 'inspect', 'context']) await refuses(action, /Save and select/);
  document.isDirty = false;
  vscode.workspace.isTrusted = false;
  for (const action of ['doctor', 'check', 'inspect', 'context']) await refuses(action, /trusted workspace/);
  vscode.workspace.isTrusted = true;
  const folders = values => values.map(value => ({ uri: { fsPath: value } }));
  const outside = platform === 'win32' ? 'D:\\Unrelated trusted folder' : '/Unrelated trusted folder';
  // Global trust is insufficient: the active project's lexical and physical
  // location must belong to one of the currently trusted workspace folders.
  vscode.workspace.workspaceFolders = folders([outside]);
  for (const action of ['doctor', 'check', 'inspect', 'context']) await refuses(action, /inside a trusted workspace folder/);
  const prefixSibling = root + '-untrusted';
  const siblingSource = paths.join(prefixSibling, 'src', 'EditorProbe.hs');
  files.add(paths.join(prefixSibling, 'fp-game.json'));
  document.uri.fsPath = siblingSource;
  vscode.workspace.workspaceFolders = folders([root]);
  for (const action of ['doctor', 'check', 'inspect', 'context']) await refuses(action, /inside a trusted workspace folder/);
  document.uri.fsPath = source;
  // Opening only a nested source folder does not authorize its parent project.
  vscode.workspace.workspaceFolders = folders([paths.join(root, 'src')]);
  await refuses('check', /inside a trusted workspace folder/);
  vscode.workspace.workspaceFolders = folders([root]);
  realPaths.set(source, paths.join(outside, 'EditorProbe.hs'));
  for (const action of ['doctor', 'check', 'inspect', 'context']) await refuses(action, /inside a trusted workspace folder/);
  realPaths.delete(source);
  // A nested project whose symlink escapes a wider trusted folder is refused.
  const physicalOutside = paths.join(outside, 'physical project');
  const nestedRoot = paths.join(root, 'nested game');
  const nestedSource = paths.join(nestedRoot, 'src', 'EditorProbe.hs');
  files.add(paths.join(nestedRoot, 'fp-game.json'));
  document.uri.fsPath = nestedSource;
  vscode.workspace.workspaceFolders = folders([root]);
  realPaths.set(nestedRoot, physicalOutside);
  realPaths.set(nestedSource, paths.join(physicalOutside, 'src', 'EditorProbe.hs'));
  await refuses('check', /inside a trusted workspace folder/);
  realPaths.delete(nestedRoot); realPaths.delete(nestedSource);
  // A real nested project and a non-first folder in multiroot both work.
  const nestedBinary = paths.join(nestedRoot, '.build', 'tools', platform === 'win32' ? 'fp-game.exe' : 'fp-game');
  files.add(nestedBinary);
  await run('check');
  assert.equal(calls.at(-1).executable, nestedBinary);
  assert.equal(calls.at(-1).options.cwd, nestedRoot);
  document.uri.fsPath = source;
  vscode.workspace.workspaceFolders = folders([outside, root]);
  await run('check'); expectCommand('check', [source]);
  vscode.workspace.workspaceFolders = [];
  await refuses('doctor', /inside a trusted workspace folder/);
  vscode.workspace.workspaceFolders = folders([root]);
  // An explicitly opened symlinked workspace is trusted at its canonical
  // target; descendants must still stay under that same canonical boundary.
  realPaths.set(root, physicalOutside);
  realPaths.set(source, paths.join(physicalOutside, 'src', 'EditorProbe.hs'));
  await run('check'); expectCommand('check', [source]);
  realPaths.clear();
  files.delete(binary);
  for (const action of ['doctor', 'check']) await refuses(action, /bootstrap-fp-game/);
  await run('inspect'); expectCommand('inspect', [source]);
  files.add(binary); files.delete(inspector);
  await run('doctor'); expectCommand('doctor');
  await run('check'); expectCommand('check', [source]);
  for (const action of ['inspect', 'context']) await refuses(action, /inspect_haskell\.py is missing/);
  files.add(inspector);
  next = { exit_code: 1, stdout: '', stderr: '' };
  await assert.rejects(run('check'), /outcome mismatch/);
  next = 'not JSON';
  await assert.rejects(run('check'), /Invalid CLI result/);
  console.log(`${platform}: native/inspector routes, saved/trusted workspace and symlink refusals, JSON outcomes, error/warning diagnostics passed`);
}

(async () => { await checkPlatform('linux'); await checkPlatform('win32'); })().catch(error => {
  console.error(error); process.exitCode = 1;
});
