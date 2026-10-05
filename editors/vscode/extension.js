const vscode = require('vscode');
const fs = require('node:fs');
const path = require('node:path');
const childProcess = require('node:child_process');

function projectRoot(file) {
  let directory = path.dirname(file);
  for (;;) {
    if (['fp-game.json', 'cabal.project'].some(name => fs.existsSync(path.join(directory, name)))) return directory;
    const parent = path.dirname(directory);
    if (directory === parent) throw new Error('Open a game or foundation project first.');
    directory = parent;
  }
}

function contains(directory, candidate) {
  const relative = path.relative(directory, candidate);
  return relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative);
}

function requireTrustedProject(root, file) {
  const allowed = vscode.workspace.workspaceFolders?.some(folder => {
    const workspace = folder.uri.fsPath;
    if (!contains(workspace, root) || (file && (!contains(workspace, file) || !contains(root, file)))) return false;
    try {
      const realWorkspace = fs.realpathSync(workspace);
      const realRoot = fs.realpathSync(root);
      const realFile = file && fs.realpathSync(file);
      return contains(realWorkspace, realRoot)
        && (!realFile || (contains(realWorkspace, realFile) && contains(realRoot, realFile)));
    } catch (_) { return false; }
  });
  if (!allowed) throw new Error('Select a project and saved file inside a trusted workspace folder.');
}

function compilerDiagnostics(text, root) {
  const result = new Map();
  const pattern = /^(.+\.hs):(\d+):(\d+)(?:-\d+)?:\s*(error|warning):/gm;
  for (const match of text.matchAll(pattern)) {
    const file = path.isAbsolute(match[1]) || !root ? match[1] : path.resolve(root, match[1]);
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
      if (!root) throw new Error('Open a game or foundation project first.');
      if (action !== 'doctor' && (!file || !file.endsWith('.hs') || editor.document.isDirty)) throw new Error('Save and select a Haskell file first.');
      requireTrustedProject(root, file);
      const native = action === 'doctor' || action === 'check';
      const entrypoint = native
        ? path.join(root, '.build', 'tools', process.platform === 'win32' ? 'fp-game.exe' : 'fp-game')
        : path.join(root, 'tools', 'inspect_haskell.py');
      if (!fs.existsSync(entrypoint)) throw new Error(native
        ? 'The project-local native fp-game is missing. Run tools/bootstrap-fp-game.sh (Windows: tools/bootstrap-fp-game.ps1) first.'
        : 'The project-local tools/inspect_haskell.py is missing.');
      const args = [action, '--project', root, '--json'];
      if (!native) args.unshift(entrypoint);
      if (action !== 'doctor') args.push(file);
      if (action === 'context') {
        const word = editor.document.getWordRangeAtPosition(editor.selection.active, /[\w']+/);
        const symbol = explicitSymbol || (word && editor.document.getText(word));
        if (!symbol) throw new Error('Place the cursor on a binding, or pass a symbol.');
        args.push('--symbol', symbol);
      }
      const executable = native ? entrypoint : vscode.workspace.getConfiguration('fpGame').get('python', 'python');
      const result = await new Promise((resolve, reject) => {
        const child = childProcess.spawn(executable, args, { cwd: root, shell: false, windowsHide: true });
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
            if (!value || !Number.isInteger(value.exit_code) || value.exit_code !== code) throw new Error('CLI/process outcome mismatch.');
            resolve(value);
          } catch (error) { reject(new Error('Invalid CLI result: ' + error.message + '\n' + stderr)); }
        });
      });
      if (action === 'check') { diagnostics.clear(); diagnostics.set(compilerDiagnostics(result.stderr || '', root)); }
      output.clear(); output.appendLine(JSON.stringify(result, null, 2)); output.show(true);
      return result;
    }));
  }
}

module.exports = { activate, compilerDiagnostics };
