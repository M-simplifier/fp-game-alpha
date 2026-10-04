const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vscode = require('vscode');

async function run() {
  const root = vscode.workspace.workspaceFolders[0].uri.fsPath;
  const source = path.join(root, 'src', 'EditorProbe.hs');
  fs.writeFileSync(source, '-- Helpers similar to module Prelude\nmodule EditorProbe where\ntwice :: Integer -> Integer\ntwice x = x + x\n');
  const document = await vscode.workspace.openTextDocument(source);
  await vscode.window.showTextDocument(document);
  const context = await vscode.commands.executeCommand('fpGame.context', 'twice');
  assert.equal(context.exit_code, 0);
  assert.equal(context.module, 'EditorProbe');
  assert.match(context.stdout, /Integer -> Integer/);
  const structure = await vscode.commands.executeCommand('fpGame.inspect');
  assert.equal(structure.module, 'EditorProbe');
  const edit = new vscode.WorkspaceEdit();
  edit.replace(document.uri, new vscode.Range(0, 0, document.lineCount, 0), 'module EditorProbe where\nbad :: Integer\nbad = True\n');
  await vscode.workspace.applyEdit(edit);
  await document.save();
  const failed = await vscode.commands.executeCommand('fpGame.check');
  assert.notEqual(failed.exit_code, 0);
  assert(vscode.languages.getDiagnostics(document.uri).some(item => item.severity === vscode.DiagnosticSeverity.Error));
  fs.writeFileSync(path.join(root, 'vscode-test-result.json'), JSON.stringify({ status: 'pass', checks: ['actual-extension-host', 'module-and-type', 'saved-source-compiler-error', 'editor-diagnostics'], vscode: vscode.version }));
}

module.exports = { run };
