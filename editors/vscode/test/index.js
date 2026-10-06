const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vscode = require('vscode');
const childProcess = require('node:child_process');

async function run() {
  const root = vscode.workspace.workspaceFolders[0].uri.fsPath;
  const source = path.join(root, 'src', 'EditorProbe.hs');
  const validSource = '-- Helpers similar to module Prelude\nmodule EditorProbe where\ntwice :: Integer -> Integer\ntwice x = x + x\n';
  fs.writeFileSync(source, validSource);
  const calls = [];
  const originalSpawn = childProcess.spawn;
  childProcess.spawn = function(executable, args, options) {
    calls.push({ executable, args, options });
    return originalSpawn.call(this, executable, args, options);
  };
  async function query(action, symbol) {
    const result = await vscode.commands.executeCommand('fpGame.' + action, symbol);
    const call = calls.at(-1);
    assert(call, 'Editor command did not spawn a process');
    const native = action === 'doctor' || action === 'check';
    const entrypoint = native
      ? path.join(root, '.build', 'tools', process.platform === 'win32' ? 'fp-game.exe' : 'fp-game')
      : path.join(root, 'tools', 'inspect_haskell.py');
    if (native) assert.equal(call.executable, entrypoint);
    else assert.equal(call.executable, vscode.workspace.getConfiguration('fpGame').get('python', 'python'));
    assert.deepEqual(call.args, [...(native ? [] : [entrypoint]), action, '--project', root, '--json',
      ...(action === 'doctor' ? [] : [source]), ...(action === 'context' ? ['--symbol', symbol] : [])]);
    assert.equal(call.options.cwd, root);
    assert.equal(call.options.shell, false);
    if (native && process.env.FP_GAME_EDITOR_COMPILER) {
      const normalize = value => process.platform === 'win32' ? path.resolve(value).toLowerCase() : path.resolve(value);
      const selected = action === 'doctor' ? result.compiler_selection.path : result.command[0];
      assert.equal(normalize(selected), normalize(process.env.FP_GAME_EDITOR_COMPILER));
    }
    return result;
  }
  try {
    const document = await vscode.workspace.openTextDocument(source);
    await vscode.window.showTextDocument(document);
    const doctor = await query('doctor');
    assert.equal(doctor.implementation, 'haskell');
    assert.equal(doctor.exit_code, 0);
    const checked = await query('check');
    assert.equal(checked.exit_code, 0);
    const context = await query('context', 'twice');
    assert.equal(context.exit_code, 0);
    assert.equal(context.module, 'EditorProbe');
    assert.match(context.stdout, /Integer -> Integer/);
    const structure = await query('inspect');
    assert.equal(structure.module, 'EditorProbe');
    const edit = new vscode.WorkspaceEdit();
    edit.replace(document.uri, new vscode.Range(0, 0, document.lineCount, 0), 'module EditorProbe where\nbad :: Integer\nbad = True\n');
    await vscode.workspace.applyEdit(edit);
    await document.save();
    const failed = await query('check');
    assert.notEqual(failed.exit_code, 0);
    assert(vscode.languages.getDiagnostics(document.uri).some(item => item.severity === vscode.DiagnosticSeverity.Error
      && /Integer/.test(item.message) && /Bool/.test(item.message)));
    const repair = new vscode.WorkspaceEdit();
    repair.replace(document.uri, new vscode.Range(0, 0, document.lineCount, 0), validSource.replace('module EditorProbe where\n', 'module EditorProbe where\nimport Data.List (sort)\n'));
    await vscode.workspace.applyEdit(repair);
    await document.save();
    const warning = await query('check');
    assert.equal(warning.exit_code, 0);
    const diagnostics = vscode.languages.getDiagnostics(document.uri);
    assert(diagnostics.some(item => item.severity === vscode.DiagnosticSeverity.Warning));
    assert(!diagnostics.some(item => item.severity === vscode.DiagnosticSeverity.Error));
    const clean = new vscode.WorkspaceEdit();
    clean.replace(document.uri, new vscode.Range(0, 0, document.lineCount, 0), validSource);
    await vscode.workspace.applyEdit(clean);
    await document.save();
    assert.equal((await query('check')).exit_code, 0);
    assert.equal(vscode.languages.getDiagnostics(document.uri).length, 0, 'clean check clears selected document diagnostics');
    fs.writeFileSync(path.join(root, 'vscode-test-result.json'), JSON.stringify({ status: 'pass', checks: ['actual-extension-host', 'native-doctor-and-check', 'inspector-command-selection', 'module-and-type', 'saved-source-compiler-error', 'editor-diagnostics', 'successful-native-warning-clears-errors', 'clean-check-clears-diagnostics'], vscode: vscode.version }));
  } finally {
    childProcess.spawn = originalSpawn;
  }
}

module.exports = { run };
