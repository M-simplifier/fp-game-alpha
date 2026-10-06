// Real subprocess integration for the VSCode adapter. Only the host UI is
// mocked: project creation, native doctor/check, and GHC/GHCi inspection run.
// This is not an installed VSCode extension-host or HLS test.
const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

async function main() {
  const foundation = path.resolve(__dirname, '..', '..', '..');
  const supplied = process.argv.slice(2);
  const options = new Map();
  for (let index = 0; index < supplied.length; index += 2) {
    const key = supplied[index];
    if (!['--binary', '--windows-compiler'].includes(key) || !supplied[index + 1] || options.has(key)) {
      throw new Error('Usage: node editors/vscode/test/native-contract.js [--binary PATH] [--windows-compiler PATH]');
    }
    options.set(key, supplied[index + 1]);
  }
  const compilerValue = options.get('--windows-compiler') || process.env.FP_GAME_COMPILER;
  if (process.platform === 'win32' && !compilerValue) {
    throw new Error('Windows acceptance requires --windows-compiler or FP_GAME_COMPILER from the declared toolchain profile');
  }
  // Preserve an explicitly chosen wrapper; never resolve compiler symlinks or
  // guess a replacement. The inspector separately requires PATH GHC/GHCi.
  const compiler = compilerValue ? path.resolve(compilerValue) : undefined;
  if (compiler) {
    assert(!/[\x00-\x1f]/.test(compiler), 'Compiler path contains a control character');
    assert(fs.statSync(compiler).isFile(), 'The explicitly selected compiler does not exist');
  }
  const normalized = value => process.platform === 'win32' ? path.resolve(value).toLowerCase() : path.resolve(value);
  const leaf = process.platform === 'win32' ? 'fp-game.exe' : 'fp-game';
  const binary = path.resolve(options.get('--binary') || process.env.FP_GAME_BINARY || path.join(foundation, '.build', 'tools', leaf));
  assert(fs.statSync(binary).isFile(), 'Bootstrap the native fp-game executable first');
  const trial = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'FP native adapter '));
  const root = path.join(trial, 'independent editor game');
  try {
    const created = childProcess.spawnSync(binary, ['create', 'editor-fixture', root, '--project', foundation, '--json'], {
      cwd: trial, shell: false, encoding: 'utf8', timeout: 180000, windowsHide: true,
    });
    assert.equal(created.error, undefined);
    assert.equal(created.status, 0, created.stdout + created.stderr);
    assert.equal(JSON.parse(created.stdout).exit_code, created.status);
    assert.equal(created.stderr, '');
    if (compiler) fs.writeFileSync(path.join(root, 'cabal.project.local'),
      'with-compiler: ' + compiler.replace(/\\/g, '/') + '\n', { encoding: 'utf8', flag: 'wx' });
    const localBinary = path.join(root, '.build', 'tools', leaf);
    fs.mkdirSync(path.dirname(localBinary), { recursive: true });
    fs.copyFileSync(binary, localBinary);
    fs.chmodSync(localBinary, fs.statSync(binary).mode);
    const inspector = path.join(root, 'tools', 'inspect_haskell.py');
    assert(fs.statSync(inspector).isFile());
    assert(!fs.existsSync(path.join(root, 'tools', 'fp_game.py')), 'Generated project must not retain the competing Python CLI');
    const source = path.join(root, 'src', 'EditorProbe.hs');
    const goodSource = 'module EditorProbe where\ntwice :: Integer -> Integer\ntwice x = x + x\n';
    fs.writeFileSync(source, goodSource);
    const commands = new Map();
    const calls = [];
    let entries = [];
    let pythonReads = 0;
    const python = process.env.FP_GAME_TEST_PYTHON || 'python';
    class Position {
      constructor(line, character) { this.line = line; this.character = character; }
      translate(line, character) { return new Position(this.line + line, this.character + character); }
    }
    class Range { constructor(start, end) { this.start = start; this.end = end; } }
    class Diagnostic { constructor(range, message, severity) { Object.assign(this, { range, message, severity }); } }
    const document = { uri: { fsPath: source }, isDirty: false,
      getWordRangeAtPosition: () => ({}), getText: () => 'twice' };
    const vscode = {
      Position, Range, Diagnostic, DiagnosticSeverity: { Error: 0, Warning: 1 }, Uri: { file: file => ({ fsPath: file }) },
      workspace: { isTrusted: true, workspaceFolders: [{ uri: { fsPath: root } }],
        getConfiguration: () => ({ get: () => { pythonReads++; return python; } }) },
      window: { activeTextEditor: { document, selection: { active: {} } },
        createOutputChannel: () => ({ clear() {}, appendLine() {}, show() {} }) },
      languages: { createDiagnosticCollection: () => ({ clear() { entries = []; }, set(value) { entries = value; } }) },
      commands: { registerCommand: (name, callback) => { commands.set(name, callback); return {}; } },
    };
    const tracedProcess = { spawn(executable, args, options) {
      calls.push({ executable, args: [...args], options });
      return childProcess.spawn(executable, args, options);
    } };
    const module = { exports: {} };
    vm.runInNewContext(fs.readFileSync(path.join(foundation, 'editors', 'vscode', 'extension.js'), 'utf8'), {
      module, process, setTimeout, clearTimeout,
      require: name => ({ vscode, 'node:fs': fs, 'node:path': path, 'node:child_process': tracedProcess })[name],
    }, { filename: 'extension.js' });
    module.exports.activate({ subscriptions: [] });
    let selectedRoot = root;
    let reportedPathAliasObserved = false;
    async function query(action, symbol) {
      const result = await commands.get('fpGame.' + action)(symbol);
      const native = action === 'doctor' || action === 'check';
      const call = calls.at(-1);
      assert.equal(call.executable, native ? path.join(selectedRoot, '.build', 'tools', leaf) : python);
      assert.deepEqual(call.args, [...(native ? [] : [path.join(selectedRoot, 'tools', 'inspect_haskell.py')]), action, '--project', selectedRoot, '--json',
        ...(action === 'doctor' ? [] : [document.uri.fsPath]), ...(action === 'context' ? ['--symbol', symbol] : [])]);
      assert.equal(call.options.cwd, selectedRoot);
      assert.equal(call.options.shell, false);
      if (compiler && native) {
        const selected = action === 'doctor' ? result.compiler_selection.path : result.command[0];
        assert.equal(normalized(selected), normalized(compiler), 'native editor command must honor the explicit compiler');
      }
      if (action === 'check') {
        const selected = fs.statSync(document.uri.fsPath, { bigint: true });
        for (const match of (result.stderr || '').matchAll(/^(.+\.hs):\d+:\d+(?:-\d+)?:\s*(?:error|warning):/gm)) {
          const reported = path.resolve(selectedRoot, match[1]);
          if (reported === document.uri.fsPath) continue;
          try {
            const actual = fs.statSync(reported, { bigint: true });
            if (actual.isFile() && actual.ino !== 0n && actual.dev === selected.dev && actual.ino === selected.ino) reportedPathAliasObserved = true;
          } catch (_) { /* A missing/imported diagnostic must not count as a source alias. */ }
        }
      }
      return result;
    }
    const doctor = await query('doctor');
    assert.equal(doctor.implementation, 'haskell');
    assert.equal(doctor.exit_code, 0, JSON.stringify(doctor));
    assert.equal((await query('check')).exit_code, 0);
    assert.equal(entries.length, 0);
    assert.equal(pythonReads, 0, 'native doctor/check never consult Python configuration');
    const structure = await query('inspect');
    assert.equal(structure.exit_code, 0, JSON.stringify(structure));
    assert.equal(structure.module, 'EditorProbe');
    const context = await query('context', 'twice');
    assert.equal(context.exit_code, 0, JSON.stringify(context));
    assert.equal(context.module, 'EditorProbe');
    assert.match(context.stdout, /Integer -> Integer/);
    fs.writeFileSync(source, 'module EditorProbe where\nbad :: Integer\nbad = True\n');
    const failed = await query('check');
    assert.notEqual(failed.exit_code, 0);
    assert(entries.some(([uri, diagnostics]) => uri === document.uri && diagnostics.some(value =>
      value.severity === 0 && /Integer/.test(value.message) && /Bool/.test(value.message))), JSON.stringify(entries));
    fs.writeFileSync(source, goodSource.replace('module EditorProbe where\n', 'module EditorProbe where\nimport Data.List (sort)\n'));
    const warning = await query('check');
    assert.equal(warning.exit_code, 0);
    assert(entries.some(([uri, diagnostics]) => uri === document.uri && diagnostics.some(value => value.severity === 1)), JSON.stringify(entries));
    assert(!entries.some(([, diagnostics]) => diagnostics.some(value => value.severity === 0)), 'successful warning check clears old errors');
    fs.writeFileSync(source, goodSource);
    assert.equal((await query('check')).exit_code, 0);
    assert.equal(entries.length, 0, 'clean native check clears all stale diagnostics');

    if (process.platform !== 'win32') {
      // Exercise a real explicitly trusted symlink workspace and real GHC,
      // independent of platform-mocked Windows file IDs in adapter-contract.js.
      selectedRoot = path.join(trial, 'opened workspace link');
      fs.symlinkSync(root, selectedRoot, 'dir');
      document.uri = { fsPath: path.join(selectedRoot, 'src', 'EditorProbe.hs') };
      vscode.workspace.workspaceFolders = [{ uri: { fsPath: selectedRoot } }];
      fs.writeFileSync(source, 'module EditorProbe where\nbad :: Integer\nbad = True\n');
      assert.notEqual((await query('check')).exit_code, 0);
      assert(entries.some(([uri, diagnostics]) => uri === document.uri && diagnostics.some(value => value.severity === 0)), JSON.stringify(entries));
      const siblingSource = path.join(trial, 'unrelated', 'EditorProbe.hs');
      fs.mkdirSync(path.dirname(siblingSource));
      fs.writeFileSync(siblingSource, goodSource);
      const routed = module.exports.compilerDiagnostics(
        `${source}:3:7: error: physical source\n\n${siblingSource}:3:7: warning: unrelated file\n\n`, selectedRoot, document.uri);
      assert.equal(routed.length, 2);
      assert.equal(routed[0][0], document.uri, 'physical path must route to the exact opened symlink URI');
      assert.equal(routed[1][0].fsPath, siblingSource, 'a real same-basename sibling must remain separate');
      fs.writeFileSync(source, goodSource.replace('module EditorProbe where\n', 'module EditorProbe where\nimport Data.List (sort)\n'));
      assert.equal((await query('check')).exit_code, 0);
      assert(entries.some(([uri, diagnostics]) => uri === document.uri && diagnostics.some(value => value.severity === 1)), JSON.stringify(entries));
      assert(!entries.some(([, diagnostics]) => diagnostics.some(value => value.severity === 0)), 'symlink warning check clears old errors');
      fs.writeFileSync(source, goodSource);
      assert.equal((await query('check')).exit_code, 0);
      assert.equal(entries.length, 0, 'clean symlink check clears stale diagnostics');
      selectedRoot = root;
      document.uri = { fsPath: source };
      vscode.workspace.workspaceFolders = [{ uri: { fsPath: root } }];
    }

    async function refuses(action, pattern) {
      const count = calls.length;
      await assert.rejects(commands.get('fpGame.' + action)(), pattern);
      assert.equal(calls.length, count, 'refusal must not run a fallback');
    }
    document.isDirty = true;
    await refuses('check', /Save and select/);
    document.isDirty = false;
    fs.renameSync(localBinary, localBinary + '.hidden');
    await refuses('doctor', /bootstrap-fp-game/);
    await refuses('check', /bootstrap-fp-game/);
    assert.equal((await query('inspect')).exit_code, 0, 'inspector remains independently available');
    fs.renameSync(localBinary + '.hidden', localBinary);
    fs.renameSync(inspector, inspector + '.hidden');
    assert.equal((await query('doctor')).implementation, 'haskell');
    assert.equal((await query('check')).exit_code, 0, 'native operations remain independent of the inspector');
    await refuses('inspect', /inspect_haskell\.py is missing/);
    await refuses('context', /inspect_haskell\.py is missing/);
    console.log(JSON.stringify({ status: 'pass', host: 'mocked-vscode-ui', processes: 'real-native-cli-and-ghc-ghci',
      checks: ['native-created-independent-game', 'native-doctor', 'saved-source-check', 'inspector-module-and-type',
        'selected-uri-error-and-successful-warning-diagnostics', 'clean-check-clears-diagnostics', 'saved-source-refusal', 'missing-entrypoint-no-fallback',
        ...(process.platform === 'win32' ? [] : ['real-trusted-symlink-workspace-diagnostics', 'distinct-file-diagnostics'])],
      platform: process.platform, reported_path_alias_observed: reportedPathAliasObserved,
      inspector_compiler_selection: 'separate PATH GHC/GHCi; native compiler profile is not applied' }));
  } catch (error) {
    console.error('Native editor fixture retained at ' + trial);
    throw error;
  }
  fs.rmSync(trial, { recursive: true, force: true });
}

main().catch(error => { console.error(error); process.exitCode = 1; });
