const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { pathToFileURL } = require('node:url');
const ts = require('typescript');
const root = path.join(__dirname, '..');
function load(file, extra = {}) {
  const exports = {};
  const code = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, jsx: ts.JsxEmit.React },
  }).outputText;
  vm.runInNewContext(code, { exports, require: name => name === './editor-diagnostics' ? helpers : require(name), TextEncoder, setTimeout, clearTimeout, ...extra });
  return exports;
}
const helpers = load('utils/editor-diagnostics.ts');

test('payload validation and bounded compiler coordinates, including Unicode and wrapper errors', () => {
  for (const bad of [null, '{}', '[null]', '[{"line":1}]', 'nope']) assert.equal(helpers.parseDiagnostics(bad), null);
  const diagnostic = (line, col) => ({ line, col, diagnostic_type: 'Error', message: 'bad' });
  const error = JSON.stringify([diagnostic(0, 0), diagnostic(1, 2), diagnostic(2, 6), diagnostic(99, 1)]);
  const markers = helpers.compilerMarkers(error, 'abc\n😀\txyz');
  assert.equal(markers.length, 2);
  assert.equal(markers[0].startColumn, 2);
  assert.equal(markers[1].startColumn, 1);
  assert.equal(markers[1].endColumn, 7);
  assert.equal(helpers.compilerMarkers(JSON.stringify(Array(200).fill(diagnostic(1, 1))), 'x').length, 100);
});

test('result panels cap diagnostics separately from markers and show truncation', () => {
  const diagnostic = { line: 1, col: 1, diagnostic_type: 'Error', message: 'bad' };
  assert.equal(helpers.parseDiagnostics(JSON.stringify(Array(500).fill(diagnostic))).length, 500);
  const payload = JSON.stringify(Array(5000).fill(diagnostic));
  const parsed = helpers.parseDiagnostics(payload);
  assert.equal(parsed.length, 501);
  assert.equal(parsed.at(-1).diagnostic_type, 'Note');
  assert.equal(parsed.at(-1).line, 0);
  assert.match(parsed.at(-1).message, /4500 additional diagnostics omitted/);
  assert.equal(helpers.compilerMarkers(payload, 'x').length, 100);
  assert.equal(helpers.parseDiagnostics(JSON.stringify([...Array(500).fill(diagnostic), null])), null);
});

test('persisted default off and compiler identities reject restoration, off/on, navigation and concurrent Run/Submit', () => {
  const storage = new Map();
  const localStorage = { getItem: k => storage.get(k) ?? null, setItem: (k,v) => storage.set(k,v), removeItem: k => storage.delete(k) };
  global.localStorage = localStorage;
  const { useStore, useSession } = load('utils/state.ts', { localStorage });
  const store = useStore.getState();
  const session = useSession.getState();
  assert.equal(store.inlineCodeChecks, false);
  assert.equal(session.beginCompilerCheck(1, 'cpp', 'x'), null);
  store.setInlineCodeChecks(true);
  assert.equal(JSON.parse(storage.get('data')).state.inlineCodeChecks, true);
  session.mountDiagnosticEditor();
  const begin = () => session.beginCompilerCheck(1, 'cpp', 'x');
  const first = begin(), second = begin();
  session.finishCompilerCheck(second, 'new');
  session.finishCompilerCheck(first, 'old');
  assert.equal(useSession.getState().compilerError, 'new');
  for (const invalidate of [() => store.setProblemImpl(1, 'x'), () => store.setProblemLanguage(1, 'rust'),
    () => { store.setInlineCodeChecks(false); store.setInlineCodeChecks(true); }, () => session.mountDiagnosticEditor()]) {
    const request = begin(); invalidate(); session.finishCompilerCheck(request, 'stale');
    assert.equal(useSession.getState().compilerError, null);
  }
  session.finishCompilerCheck(begin(), 'failure');
  session.finishCompilerCheck(begin());
  assert.equal(useSession.getState().compilerError, null);
  delete global.localStorage;
});

test('scheduler debounces, bounds concurrency, rejects stale replies, and cleans up failures/off', () => {
  let clock = 0, next = 0;
  const timers = new Map();
  const tick = ms => { clock += ms; for (const [id, t] of [...timers]) if (t.at <= clock) { timers.delete(id); t.fn(); } };
  const { syntaxChecks } = load('utils/syntax-checks.ts', { setTimeout: (fn, ms) => { const id = ++next; timers.set(id, { fn, at: clock + ms }); return id; }, clearTimeout: id => timers.delete(id) });
  const sent = [], delivered = [], statuses = [];
  let starts = 0, stopped = 0;
  const worker = { postMessage: r => sent.push(r), terminate: () => stopped++, onmessage: null, onerror: null };
  const checks = syntaxChecks(() => { starts++; return worker; }, r => delivered.push(r), s => statuses.push(s));
  const update = revision => checks.update({ editor: 1, session: 2, revision, version: revision, source: 'x', language: 'cpp' });
  assert.equal(starts, 0);
  update(1); tick(299); assert.equal(starts, 0); update(2); tick(300); assert.equal(sent.length, 1);
  update(3); tick(300); update(4); tick(300); assert.equal(sent.length, 1);
  worker.onmessage({ data: { ...sent[0], markers: [] } });
  assert.equal(delivered.length, 0); assert.equal(sent.length, 2); assert.equal(sent[1].revision, 4);
  worker.onmessage({ data: { ...sent[1], session: 1, markers: [] } }); assert.equal(delivered.length, 0);
  worker.onmessage({ data: { ...sent[1], markers: [] } }); assert.equal(delivered.length, 1);
  update(5); tick(300); const late = worker.onmessage; checks.dispose(); late({ data: { ...sent[2], markers: [] } });
  assert.equal(delivered.length, 1); assert.equal(stopped, 1); assert.equal(timers.size, 0);
  const failing = syntaxChecks(() => worker, () => assert.fail(), s => statuses.push(s));
  failing.update({ editor: 1, session: 3, revision: 1, version: 1, language: 'rust', source: 'x' }); tick(300); tick(2000);
  assert.match(statuses.at(-1), /unavailable/);
  failing.update({ source: '😀'.repeat(60000) }); assert.match(statuses.at(-1), /200 KiB/); failing.dispose();
});

test('editor effects survive Strict Mode setup/cleanup replay and disposed Monaco models', () => {
  const effects = [], timers = new Map(), subscriptions = new Set(), workers = [];
  let id = 0, disposed = false;
  const subscribe = fn => { subscriptions.add(fn); return () => subscriptions.delete(fn); };
  const state = { diagnosticEditor: 0, diagnosticGeneration: 0, diagnosticRevision: 0,
    mountDiagnosticEditor() { this.diagnosticEditor++; },
    invalidateDiagnostics() { this.diagnosticRevision++; },
  };
  const store = selector => selector({ inlineCodeChecks: true });
  store.getState = () => ({ inlineCodeChecks: true }); store.subscribe = subscribe;
  const model = { isDisposed: () => disposed, getValue: () => { assert.equal(disposed, false); return 'int x;'; },
    getVersionId: () => 1, onDidChangeContent: fn => ({ dispose: subscribe(fn) }) };
  const syntax = load('utils/syntax-checks.ts', {
    setTimeout: fn => { timers.set(++id, fn); return id; }, clearTimeout: key => timers.delete(key),
  });
  const component = load('components/editor-diagnostics.tsx', {
    React: { createElement: () => null },
    Worker: class { constructor() { workers.push(this); } postMessage() {} terminate() { this.terminated = true; } },
    require: name => ({ react: { useEffect: fn => effects.push(fn), useState: () => ['', () => {}] },
      'monaco-editor': { editor: { setModelMarkers() { assert.equal(disposed, false); } } },
      '../utils/editor-diagnostics': helpers,
      '../utils/state': { useStore: store, useSession: { getState: () => state, subscribe } },
      '../utils/syntax-checks': syntax })[name],
  });
  component.default({ editor: { getModel: () => model }, problem: 1, language: 'cpp' });
  for (let replay = 0; replay < 2; replay++) {
    const cleanups = effects.map(setup => setup());
    for (const [key, fn] of [...timers]) { timers.delete(key); fn(); }
    assert.equal(workers.filter(w => !w.terminated).length, 1);
    assert.equal(subscriptions.size, 3);
    if (replay === 1) disposed = true;
    cleanups.forEach(cleanup => cleanup());
    assert.equal(workers.filter(w => !w.terminated).length, 0);
    assert.equal(subscriptions.size, 0);
    assert.equal(timers.size, 0);
  }
});

test('actual pinned C++/Rust grammars: templates, errors, Unicode UTF-16 offsets, CRLF, macros and 50 KiB', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'editor-parser-'));
  const assets = path.join(root, 'public/editor-diagnostics');
  try {
    const hashes = {
      'web-tree-sitter.js': '7c49e3c1d87e24e0bb4c2def909d17154dfde281f5f8280225450090bb4b8110',
      'web-tree-sitter.wasm': 'c03bccdc3b448a32848f5ae327e209c982bbb0840d43eec8bc2d5759544a1ed3',
      'tree-sitter-cpp.wasm': '174eb0deb75b2ec7881bcacda9f995648d8e683956e5c2267e69ab6dc503fcbf',
      'tree-sitter-rust.wasm': 'f65f354215611fd94ad34134b3427eb3d58cbb745df7b6509ba722184db73d57',
    };
    for (const [file, hash] of Object.entries(hashes)) assert.equal(require('node:crypto').createHash('sha256').update(fs.readFileSync(path.join(assets, file))).digest('hex'), hash);
    const runtime = path.join(dir, 'runtime.mjs');
    fs.copyFileSync(path.join(assets, 'web-tree-sitter.js'), runtime);
    const { Parser, Language } = await import(pathToFileURL(runtime).href);
    await Parser.init({ locateFile: () => path.join(assets, 'web-tree-sitter.wasm') });
    for (const language of ['cpp', 'rust']) {
      const parser = new Parser();
      parser.setLanguage(await Language.load(path.join(assets, `tree-sitter-${language}.wasm`)));
      const valid = language === 'cpp' ? '#define X 1\r\nint solve(int x) { /* 😀é */ return x + X; }' : 'pub fn solve(x: i32) -> i32 { /* 😀é */ println!("hi"); x }';
      for (const source of [valid, valid + '\n//' + 'x'.repeat(50 * 1024)]) {
        const tree = parser.parse(source); assert.equal(tree.rootNode.hasError, false); assert.equal(tree.rootNode.endIndex, source.length); tree.delete();
      }
      for (const source of [valid.slice(0, -1), language === 'cpp' ? 'int solve(' : 'pub fn solve(']) {
        const tree = parser.parse(source); assert.equal(tree.rootNode.hasError, true); tree.delete();
      }
      const source = language === 'cpp' ? 'int f(){ /*😀*/ return @; }' : 'fn f(){ /*😀*/ let x = @; }';
      const tree = parser.parse(source);
      const errors = tree.rootNode.descendantsOfType('ERROR');
      assert.ok(errors.some(node => node.startIndex <= source.indexOf('@') && node.endIndex === source.indexOf('@') + 1));
      for (const node of errors) assert.equal(node.text, source.slice(node.startIndex, node.endIndex));
      tree.delete(); parser.delete();
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
