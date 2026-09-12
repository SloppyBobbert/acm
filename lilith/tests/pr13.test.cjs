// Component contract checks with mocked hooks/network, not browser tests.
// Run: node --test tests/pr13.test.cjs (after the normal frontend install).
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require('typescript');
const root = path.resolve(__dirname, '..');
const user = { id: 1, name: 'Alice', username: 'alice.old', auth: 'MEMBER' };
const flush = () => new Promise(setImmediate);

function component(file, extra = '') {
  const h = { values: [], cursor: 0, effects: [], updates: 0, errors: [], mutations: [], routes: [], keys: [], sockets: [] };
  h.router = { query: {}, isReady: true, asPath: '/', events: { on() {}, off() {} },
    push: url => h.routes.push(url), replace: url => h.routes.push(url) };
  const react = {
    useState(initial) {
      const i = h.cursor++;
      if (!(i in h.values)) h.values[i] = typeof initial === 'function' ? initial() : initial;
      return [h.values[i], update => {
        h.updates++;
        h.values[i] = typeof update === 'function' ? update(h.values[i]) : update;
      }];
    },
    useRef(initial) {
      const i = h.cursor++;
      if (!(i in h.values)) h.values[i] = { current: initial };
      return h.values[i];
    },
    useEffect(effect) { h.cursor++; h.effects.push(effect); },
  };
  h.fetchers = [];
  const swr = (key, fetcher) => { h.keys.push(key); h.fetchers.push(fetcher); return { data: user }; };
  swr.useSWRConfig = () => ({ mutate: key => { h.mutations.push(key); return Promise.resolve(); } });
  h.response = { ok: true, json: async () => ({}) };
  h.requests = [];
  const context = {
    exports: {}, Map, Date, console, URL, URLSearchParams,
    window: {
      location: { search: '?code=review-code&state=review-state', href: 'http://localhost/auth/discord?code=review-code&state=review-state' },
      history: { state: {}, replaceState() {} },
    },
    process: { env: { NEXT_PUBLIC_WS_URL: 'ws://review.invalid/ws' } },
    setInterval: () => 1, clearInterval() {},
    fetch: (...args) => {
      h.requests.push(args);
      return h.networkError ? Promise.reject(h.networkError) : Promise.resolve(h.response);
    },
    WebSocket: class {
      constructor() { this.listeners = {}; h.sockets.push(this); }
      addEventListener(name, callback) { this.listeners[name] = callback; }
      close() {}
    },
    require(name) {
      if (name === 'react') return react;
      if (name === 'react/jsx-runtime') return { jsx: (type, props) => ({ type, props }), jsxs: (type, props) => ({ type, props }), Fragment: 'fragment' };
      if (name === 'next/router') return { useRouter: () => h.router };
      if (name === 'swr') return swr;
      if (name.endsWith('/utils/fetcher')) return { api_url: value => 'api:' + value, fetcher: url => h.requests.push([url]) };
      if (name.endsWith('/utils/state')) return { useSession: select => select({ setError: (...args) => h.errors.push(args) }) };
      return name;
    },
  };
  const source = readFileSync(path.join(root, file), 'utf8') + extra;
  const code = ts.transpileModule(source, { compilerOptions: {
    jsx: ts.JsxEmit.ReactJSX, module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true,
  } }).outputText;
  vm.runInNewContext(code, context, { filename: file });
  h.exports = context.exports;
  h.render = (fn = h.exports.default, props = {}) => {
    h.cursor = 0; h.effects = []; h.keys = [];
    return fn(props);
  };
  return h;
}

function find(tree, predicate) {
  if (!tree || typeof tree !== 'object') return undefined;
  if (Array.isArray(tree)) {
    for (const child of tree) { const found = find(child, predicate); if (found) return found; }
    return undefined;
  }
  return predicate(tree) ? tree : find(tree.props?.children, predicate);
}

for (const lifecycle of ['unmounted', 'strict-replay']) {
  for (const outcome of ['success', 'http-error', 'network-error']) {
    test(`Discord ${outcome} after ${lifecycle} preserves single-use exchange`, async () => {
      const h = component('pages/auth/discord.tsx');
      let resolve, reject;
      h.response = new Promise((done, fail) => { resolve = done; reject = fail; });
      h.render();
      const cleanups = h.effects.map(effect => effect());
      cleanups.forEach(cleanup => cleanup?.());
      if (lifecycle === 'strict-replay') h.effects.forEach(effect => effect());
      const before = h.updates;
      if (outcome === 'network-error') reject(new Error('offline'));
      else resolve({ ok: outcome === 'success' });
      await flush();
      assert.equal(h.requests.length, 1);
      assert.equal(h.requests[0][0], 'api:/auth/discord');
      assert.equal(h.requests[0][1].signal, undefined);
      const active = lifecycle === 'strict-replay';
      assert.deepEqual(h.routes, active && outcome === 'success' ? ['/'] : []);
      assert.equal(h.updates - before, active && outcome !== 'success' ? 1 : 0);
    });
  }
}

const profile = () => component('pages/user/[username].tsx', '\nexports.UserEditor = UserEditor;');

for (const response of [{ ok: false, json: async () => ({}) }, { ok: true, json: async () => ({ error: 'taken' }) }]) {
  test(`profile update stops on ${response.ok ? 'API' : 'HTTP'} error`, async () => {
    const h = profile(); h.response = response;
    let done = 0;
    const tree = h.render(h.exports.UserEditor, { ...user, onDone: () => done++ });
    tree.props.onSubmit({ preventDefault() {} });
    await flush();
    assert.equal(h.errors.length, 1);
    assert.equal(done, 0);
    assert.equal(h.routes.length, 0);
    assert.equal(h.mutations.length, 0);
    assert.equal(h.values[3], false);
  });
}

test('profile rename refreshes current, old, and new profile keys', async () => {
  const h = profile();
  h.values[0] = 'alice.new';
  let done = 0;
  const tree = h.render(h.exports.UserEditor, { ...user, onDone: () => done++ });
  tree.props.onSubmit({ preventDefault() {} });
  await flush();
  assert.deepEqual(h.mutations.sort(), ['api:/user/me', 'api:/user/username/alice.new', 'api:/user/username/alice.old'].sort());
  assert.deepEqual(h.routes, ['/user/alice.new']);
  assert.equal(done, 1);
});

test('existing Discord usernames are not blocked by an alphanumeric-only pattern', () => {
  const h = profile();
  const tree = h.render(h.exports.UserEditor, { ...user, onDone() {} });
  const input = find(tree, node => node.props?.id === 'profile-username');
  for (const name of ['alice.smith', 'alice_123', 'élise']) {
    assert.ok(!input.props.pattern || new RegExp(`^(?:${input.props.pattern})$`, 'u').test(name), name);
  }
});

test('non-string usernames do not create profile API requests', () => {
  const h = profile();
  h.router.query.username = ['alice', 'bob'];
  h.render();
  assert.equal(h.keys[0], null);
});

for (const networkError of [undefined, new Error('offline')]) {
  test(`logout reports ${networkError ? 'network' : 'HTTP'} failure without navigation`, async () => {
    const h = component('components/navbar.tsx');
    h.values = [false, true];
    h.response = { ok: false };
    h.networkError = networkError;
    const tree = h.render();
    const button = find(tree, node => node.type === 'button' && node.props.children === 'Sign out');
    button.props.onClick();
    await flush();
    assert.equal(h.errors.length, 1);
    assert.equal(h.routes.length, 0);
    assert.equal(h.mutations.length, 0);
  });
}

test('successful logout refreshes the session and returns home', async () => {
  const h = component('components/navbar.tsx'); h.values = [false, true];
  const button = find(h.render(), node => node.type === 'button' && node.props.children === 'Sign out');
  button.props.onClick();
  await flush();
  assert.deepEqual(h.routes, ['/']);
  assert.deepEqual(h.mutations, ['api:/user/me']);
  assert.equal(h.errors.length, 0);
});

test('expired countdown completes once across effect replay and once per new target', () => {
  const h = component('components/countdown.tsx');
  let calls = 0;
  const props = { to: new Date(0), onFinal: () => calls++ };
  h.render(h.exports.default, props);
  const cleanups = h.effects.map(effect => effect());
  cleanups.forEach(cleanup => cleanup?.());
  h.effects.forEach(effect => effect());
  assert.equal(calls, 1);
  h.render(h.exports.default, { ...props, to: new Date(1) });
  h.effects.forEach(effect => effect());
  assert.equal(calls, 2);
});

const job = { id: 1, problem_id: 1, user_id: 1, job_type: 'CustomInput', queue_position: 0 };
test('dashboard updates preserve previous maps', () => {
  const h = component('pages/dashboard/index.tsx');
  h.render(); h.effects[0]();
  const message = h.sockets[0].listeners.message;
  const original = h.values[1];
  message({ data: JSON.stringify({ NewJob: job }) });
  assert.equal(original.size, 0);
  const pending = h.values[1];
  assert.equal(pending.size, 1);
  message({ data: JSON.stringify({ FinishedJob: job }) });
  assert.equal(pending.size, 1);
  assert.equal(h.values[1].size, 0);
});

test('dashboard ignores messages after cleanup', () => {
  const h = component('pages/dashboard/index.tsx');
  h.render(); const cleanup = h.effects[0](); cleanup();
  const before = h.updates;
  h.sockets[0].listeners.message({ data: JSON.stringify({ NewJob: job }) });
  assert.equal(h.updates, before);
});

test('closed dashboard does not claim that unloaded lists are empty', () => {
  const h = component('pages/dashboard/index.tsx');
  h.values = [[], new Map(), [], 'closed'];
  const tree = h.render();
  assert.equal(find(tree, node => ['JobsList', 'CompletionsList', 'LoadingColumn'].includes(node.type?.name)), undefined);
});

test('non-editor scrollbars remain visible', () => {
  const css = readFileSync(path.join(root, 'styles/globals.css'), 'utf8');
  assert.doesNotMatch(css, /\.featured-problem-container\s+\*/);
});

test('problem filter labels target their own controls and search has a name', () => {
  const h = component('pages/problems/index.tsx');
  find(h.render(), node => node.type === 'button' && node.props.children === 'Filters').props.onClick();
  const tree = h.render();
  for (const [label, id] of [['Easy', 'easy'], ['Medium', 'medium'], ['Hard', 'hard'], ['Newest', 'newest'], ['Oldest', 'oldest'], ['Show competition problems', 'competition-problems']]) {
    assert.equal(find(tree, node => node.type === 'label' && node.props.children === label)?.props.htmlFor, id);
    assert.equal(find(tree, node => node.type === 'input' && node.props.id === id)?.type, 'input');
  }
  assert.ok(find(tree, node => node.type === 'input' && node.props['aria-label'] === 'Search problems'));
});

test('difficulty checkmarks follow filter state after closing and reopening', () => {
  const h = component('pages/problems/index.tsx');
  const toggle = () => find(h.render(), node => node.type === 'button' && node.props.children === 'Filters').props.onClick();
  toggle();
  for (const id of ['easy', 'medium', 'hard']) {
    const control = find(h.render(), node => node.type === 'input' && node.props.id === id);
    assert.equal(control.props.checked, false);
    control.props.onChange();
  }
  toggle(); toggle();
  for (const id of ['easy', 'medium', 'hard']) {
    assert.equal(find(h.render(), node => node.type === 'input' && node.props.id === id).props.checked, true);
  }
});

test('problem search preserves punctuation and cannot change other URL parameters', () => {
  const h = component('pages/problems/index.tsx', '\nexports.ProblemSearchResults = ProblemSearchResults;');
  for (const query of ['C++', 'a&count=500', 'name#part', 'résumé 100%']) {
    h.render(h.exports.ProblemSearchResults, { query });
    h.fetchers.at(-1)();
    const url = new URL(h.requests.at(-1)[0]);
    assert.equal(url.searchParams.get('query'), query);
    assert.equal(url.searchParams.get('count'), '10');
    assert.equal(url.searchParams.size, 2);
  }
});
