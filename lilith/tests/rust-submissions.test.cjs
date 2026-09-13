// Real Zustand state and persistence with in-memory localStorage; no browser or Monaco.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');
const ts = require('typescript');
const vm = require('node:vm');
const path = require('node:path');
const root = path.resolve(__dirname, '..');

function loadStore(storage) {
  const previous = global.localStorage;
  global.localStorage = storage;
  try {
    const diagnostics = { exports: {} };
    vm.runInNewContext(ts.transpileModule(readFileSync(path.join(root, 'utils/editor-diagnostics.ts'), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    }).outputText, diagnostics);
    const context = { exports: {}, require: name => name === './editor-diagnostics' ? diagnostics.exports : require(name), console };
    const code = ts.transpileModule(readFileSync(path.join(root, 'utils/state.ts'), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true },
    }).outputText;
    vm.runInNewContext(code, context);
    return context.exports;
  } finally {
    global.localStorage = previous;
  }
}

function loadHistoryButton(store, fetch) {
  let loading = false;
  const context = {
    exports: {}, fetch,
    require(name) {
      if (name === 'react') return { useContext: () => 1, useState: () => [loading, value => { loading = value; }] };
      if (name === 'react/jsx-runtime') return { jsx: (type, props) => ({ type, props }), jsxs: (type, props) => ({ type, props }) };
      if (name.endsWith('/utils/state')) return {
        useStore: select => select(store.useStore.getState()),
        useSession: select => select(store.useSession.getState()),
      };
      if (name.endsWith('/utils/fetcher')) return { api_url: value => 'api:' + value };
      return name;
    },
  };
  const source = readFileSync(path.join(root, 'components/problem/submission/history.tsx'), 'utf8') + '\nexports.LoadHistoryButton = LoadHistoryButton;';
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    jsx: ts.JsxEmit.ReactJSX, module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true,
  } }).outputText, context);
  return () => context.exports.LoadHistoryButton({ id: 91 });
}

for (const [label, response] of [
  ['HTTP error', async () => ({ ok: false, json: async () => ({ error: 'missing' }) })],
  ['HTTP error with code', async () => ({ ok: false, json: async () => ({ code: 'must not load' }) })],
  ['network error', async () => { throw new Error('offline'); }],
  ['invalid JSON', async () => ({ ok: true, json: async () => { throw new Error('invalid JSON'); } })],
  ['null body', async () => ({ ok: true, json: async () => null })],
  ['non-string code', async () => ({ ok: true, json: async () => ({ code: 7 }) })],
  ['unknown language', async () => ({ ok: true, json: async () => ({ code: 'code', language: 'unknown' }) })],
]) {
  test(`history ${label} preserves persisted drafts and clears loading`, async (t) => {
    const data = new Map();
    const storage = { getItem: key => data.get(key) ?? null, setItem: (key, value) => data.set(key, value), removeItem: key => data.delete(key) };
    const store = loadStore(storage);
    store.useStore.getState().setProblemImpl(1, 'C++ draft', 'cpp');
    store.useStore.getState().setProblemImpl(1, 'Rust draft', 'rust');
    const saved = storage.getItem('data');
    const setter = t.mock.method(store.useStore.getState(), 'setProblemImpl');
    const render = loadHistoryButton(store, response);
    const pending = render().props.onClick();
    assert.equal(render().props.loading, true);
    await pending;
    assert.equal(render().props.loading, false);
    assert.equal(storage.getItem('data'), saved);
    assert.equal(setter.mock.callCount(), 0);
    assert.equal(store.useSession.getState().errorShown, true);
    assert.equal(store.useSession.getState().error, 'Could not load submission. Try again.');
  });
}

test('history loads Rust, legacy C++, and empty code without changing other drafts', async () => {
  for (const body of [{ code: 'new Rust', language: 'rust' }, { code: 'legacy C++' }, { code: '', language: 'cpp' }]) {
    const data = new Map();
    const storage = { getItem: key => data.get(key) ?? null, setItem: (key, value) => data.set(key, value), removeItem: key => data.delete(key) };
    const store = loadStore(storage);
    store.useStore.getState().setProblemImpl(1, 'C++ draft', 'cpp');
    store.useStore.getState().setProblemImpl(1, 'Rust draft', 'rust');
    const requests = [];
    const render = loadHistoryButton(store, async (...args) => { requests.push(args); return { ok: true, json: async () => body }; });
    await render().props.onClick();
    const language = body.language ?? 'cpp';
    assert.equal(store.getProblemImpl(store.useStore.getState(), 1), body.code);
    assert.equal(store.getProblemImpl(store.useStore.getState(), 1, language === 'cpp' ? 'rust' : 'cpp'), language === 'cpp' ? 'Rust draft' : 'C++ draft');
    assert.equal(store.useStore.getState().problemLanguages[1], language);
    assert.equal(render().props.loading, false);
    assert.deepEqual(requests, [['api:/submissions/91']]);
  }
});

test('legacy C++ drafts survive switching, reload, and loading old submissions', () => {
  const data = new Map([['data', JSON.stringify({ state: { problemImpls: { 1: 'old C++' } }, version: 0 })]]);
  const storage = { getItem: key => data.get(key) ?? null, setItem: (key, value) => data.set(key, value), removeItem: key => data.delete(key) };
  let { useStore, getProblemImpl } = loadStore(storage);
  assert.equal(useStore.getState().inlineCodeChecks, false);
  assert.equal(getProblemImpl(useStore.getState(), 1), 'old C++');
  useStore.getState().setProblemLanguage(1, 'rust');
  assert.equal(getProblemImpl(useStore.getState(), 1), undefined);
  useStore.getState().setProblemImpl(1, 'fn add() {}', 'rust');
  useStore.getState().setProblemLanguage(1, 'cpp');
  assert.equal(getProblemImpl(useStore.getState(), 1), 'old C++');
  useStore.getState().setProblemLanguage(1, 'rust');
  ({ useStore, getProblemImpl } = loadStore(storage));
  assert.equal(useStore.getState().problemLanguages[1], 'rust');
  assert.equal(getProblemImpl(useStore.getState(), 1), 'fn add() {}');
  useStore.getState().setProblemImpl(1, 'loaded legacy submission');
  assert.equal(useStore.getState().problemLanguages[1], 'cpp');
  assert.equal(getProblemImpl(useStore.getState(), 1), 'loaded legacy submission');
  assert.equal(getProblemImpl(useStore.getState(), 1, 'rust'), 'fn add() {}');
});

test('both request paths send language and reject HTTP errors before job polling', () => {
  for (const file of ['components/problem/code-runner.tsx', 'components/problem/input-tester.tsx']) {
    const source = readFileSync(path.join(root, file), 'utf8');
    assert.match(source, /JSON.stringify\(\{[^}]*language/s);
    const rejection = source.indexOf('if (!res.ok)');
    const polling = source.indexOf('= await monitorJob(');
    assert.ok(rejection >= 0, `${file} must reject HTTP errors`);
    assert.ok(polling >= 0, `${file} must monitor accepted jobs`);
    assert.ok(rejection < polling);
  }
  for (const file of ['components/problem/submission/history.tsx', 'pages/submissions/[id].tsx']) {
    assert.match(readFileSync(path.join(root, file), 'utf8'), /language \?\? "cpp"/);
  }
});
