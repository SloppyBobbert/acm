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
    const context = { exports: {}, require, console };
    const code = ts.transpileModule(readFileSync(path.join(root, 'utils/state.ts'), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true },
    }).outputText;
    vm.runInNewContext(code, context);
    return context.exports;
  } finally {
    global.localStorage = previous;
  }
}

test('legacy C++ drafts survive switching, reload, and loading old submissions', () => {
  const data = new Map([['data', JSON.stringify({ state: { problemImpls: { 1: 'old C++' } }, version: 0 })]]);
  const storage = { getItem: key => data.get(key) ?? null, setItem: (key, value) => data.set(key, value), removeItem: key => data.delete(key) };
  let { useStore, getProblemImpl } = loadStore(storage);
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
