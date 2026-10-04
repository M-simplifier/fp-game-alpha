const vscode = require('vscode');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

function projectRoot(file) {
  let directory = path.dirname(file);
  for (;;) {
    if (['fp-game.json', 'cabal.project'].some(name => fs.existsSync(path.join(directory, name)))) return directory;
    const parent = path.dirname(directory);
    if (directory === parent) throw new Error('Open a game or foundation project first.');
    directory = parent;
  }
}

function compilerDiagnostics(text) {
  const result = new Map();
  const pattern = /^(.+\.hs):(\d+):(\d+)(?:-\d+)?:\s*(error|warning):/gm;
  for (const match of text.matchAll(pattern)) {
    const file = match[1];
    const position = new vscode.Position(Number(match[2]) - 1, Number(match[3]) - 1);
    const diagnostic = new vscode.Diagnostic(new vscode.Range(position, position.translate(0, 1)),
      text.slice(match.index, text.indexOf('\n\n', match.index) === -1 ? text.length : text.indexOf('\n\n', match.index)).trim(),
      match[4] === 'error' ? vscode.DiagnosticSeverity.Error : vscode.DiagnosticSeverity.Warning);
    diagnostic.source = 'fp-game / GHC saved source';
    if (!result.has(file)) result.set(file, []);
    result.get(file).push(diagnostic);
  }
  return [...result].map(([file, entries]) => [vscode.Uri.file(file), entries]);
}

function activate(context) {
  const output = vscode.window.createOutputChannel('FP Game');
  const diagnostics = vscode.languages.createDiagnosticCollection('fp-game');
  context.subscriptions.push(output, diagnostics);
  for (const action of ['doctor', 'check', 'inspect', 'context']) {
    context.subscriptions.push(vscode.commands.registerCommand('fpGame.' + action, async (explicitSymbol) => {
      if (!vscode.workspace.isTrusted) throw new Error('CLI execution requires a trusted workspace.');
      const editor = vscode.window.activeTextEditor;
      const file = editor?.document.uri.fsPath;
      const root = file ? projectRoot(file) : vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
      if (!root || !fs.existsSync(path.join(root, 'tools', 'fp_game.py'))) throw new Error('The project-local tools/fp_game.py is missing.');
      if (action !== 'doctor' && (!file || !file.endsWith('.hs') || editor.document.isDirty)) throw new Error('Save and select a Haskell file first.');
      const args = [path.join(root, 'tools', 'fp_game.py'), action, '--project', root, '--json'];
      if (action !== 'doctor') args.push(file);
      if (action === 'context') {
        const word = editor.document.getWordRangeAtPosition(editor.selection.active, /[\w']+/);
        const symbol = explicitSymbol || (word && editor.document.getText(word));
        if (!symbol) throw new Error('Place the cursor on a binding, or pass a symbol.');
        args.push('--symbol', symbol);
      }
      const python = vscode.workspace.getConfiguration('fpGame').get('python', 'python');
      const result = await new Promise((resolve, reject) => {
        const child = spawn(python, args, { cwd: root, shell: false, windowsHide: true });
        let stdout = '', stderr = '';
        child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
        const timeout = setTimeout(() => { child.kill(); reject(new Error('Compiler query timed out.')); }, 190000);
        child.stdout.on('data', chunk => { stdout += chunk; });
        child.stderr.on('data', chunk => { stderr += chunk; });
        child.on('error', error => { clearTimeout(timeout); reject(error); });
        child.on('close', code => {
          clearTimeout(timeout);
          try {
            const value = JSON.parse(stdout);
            if (value.exit_code !== code) throw new Error('CLI/process outcome mismatch.');
            resolve(value);
          } catch (error) { reject(new Error('Invalid CLI result: ' + error.message + '\n' + stderr)); }
        });
      });
      if (action === 'check') { diagnostics.clear(); diagnostics.set(compilerDiagnostics(result.stderr || '')); }
      output.clear(); output.appendLine(JSON.stringify(result, null, 2)); output.show(true);
      return result;
    }));
  }
}

module.exports = { activate, compilerDiagnostics };
