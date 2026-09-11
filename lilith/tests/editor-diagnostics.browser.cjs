// Production-browser UI acceptance. ALL API responses below are SIMULATED, never native compiler acceptance.
// Start production on :3101, then: agent-browser --session diagnostics-check open about:blank
// node lilith/tests/editor-diagnostics.browser.cjs "$(agent-browser --session diagnostics-check get cdp-url)"
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { once } = require('node:events');
const url = process.argv[2];
const origin = process.env.DIAGNOSTICS_ORIGIN || 'http://localhost:3101';
const output = path.resolve(process.env.DIAGNOSTICS_EVIDENCE || '.local/acceptance/editor-diagnostics/browser');
fs.mkdirSync(output, { recursive: true });
const fixture = () => {
  if (!sessionStorage.diagnosticsFixture) { localStorage.removeItem('data'); sessionStorage.diagnosticsFixture = '1'; }
  window.fixture = { requests: [], jobs: [], workers: [], messages: [], failAssets: false, nextError: null, deferred: false };
  const f = window.fixture;
  const original = window.fetch;
  const cpp = 'int solve(int x) { return x; }';
  window.fetch = async (url, options = {}) => {
    const u = new URL(url, location.href);
    if (!u.pathname.startsWith('/run/') && !u.pathname.startsWith('/problems/') && !u.pathname.startsWith('/submissions/') && u.pathname !== '/user/me') return original(url, options);
    f.requests.push({ path: u.pathname, method: options.method || 'GET', body: options.body });
    let body = null;
    if (u.pathname === '/user/me') body = { id: 1, username: 'simulated', name: 'Simulated UI fixture', auth: 'MEMBER' };
    else if (/^\/problems\/(991|992)$/.test(u.pathname)) body = { id: Number(u.pathname.split('/').at(-1)), title: 'Simulated diagnostics fixture', description: 'API responses simulated; real browser syntax grammars.', template: cpp };
    else if (u.pathname.endsWith('/rust-template')) body = 'pub fn solve(x: i32) -> i32 { x }';
    else if (u.pathname.endsWith('/tests/0')) body = { id: 1, input: { name: 'solve', arguments: [{ Int: { Single: 1 } }], return_type: { Int: 'Single' } }, expected_output: { Int: { Single: 1 } } };
    else if (u.pathname.endsWith('/history')) body = [{ id: 91, problem_id: 991, code: cpp, language: 'cpp', success: false, error: 'Simulated history', time: '2026-01-01T00:00:00' }];
    else if (u.pathname === '/submissions/91') body = { id: 91, problem_id: 991, code: f.historySource || cpp, language: f.historyLanguage || 'cpp' };
    else if (u.pathname.endsWith('/leaderboard') || u.pathname.endsWith('/tests')) body = [];
    else if (u.pathname === '/run/custom' || u.pathname === '/run/submit') {
      const id = f.jobs.length + 1;
      f.jobs.push({ id, path: u.pathname, error: f.nextError, deferred: f.deferred });
      body = { id, queue_position: 0 };
    } else if (u.pathname.startsWith('/run/check/')) {
      const job = f.jobs[Number(u.pathname.split('/').at(-1)) - 1];
      if (job.deferred) await new Promise(resolve => { job.release = resolve; });
      job.finished = true;
      body = job.error ? { id: job.id, error: job.error } : { id: job.id, response: job.path === '/run/submit'
        ? { id: job.id, problem_id: 991, code: cpp, success: true, runtime: 1 }
        : { result: { expected_output: { Int: { Single: 1 } }, output: { Int: { Single: 1 } }, success: true, runtime: 1 }, output: '' } };
    }
    return new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/json' } });
  };
  const NativeWorker = window.Worker;
  window.Worker = class extends NativeWorker {
    constructor(url, options) {
      const syntax = String(url).includes('/editor-diagnostics/');
      super(syntax && f.failAssets ? '/missing-syntax-worker.js' : url, options);
      if (syntax) {
        this.record = { url: String(url), terminated: false };
        f.workers.push(this.record);
        this.addEventListener('message', event => f.messages.push(event.data));
      }
    }
    terminate() { if (this.record) this.record.terminated = true; super.terminate(); }
  };
  window.editorModel = () => {
    const root = document.getElementById('__next');
    const key = Object.keys(root).find(k => k.startsWith('__reactContainer'));
    const start = root[key]?.stateNode?.current;
    const visit = node => {
      if (!node) return null;
      if (node.memoizedProps?.editor?.getModel) return node.memoizedProps.editor.getModel();
      return visit(node.child) || visit(node.sibling);
    };
    return visit(start);
  };
  window.inlineMarkers = () => (window.editorModel()?.getAllDecorations() || []).filter(d => /squiggly/.test(d.options.className || '')).map(d => ({ range: d.range, message: d.options.hoverMessage, className: d.options.className }));
};

(async () => {
  const ws = new WebSocket(url); await once(ws, 'open');
  let serial = 0, session;
  const pending = new Map(), exceptions = [], network = [], milestones = [];
  ws.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.id) { const p = pending.get(message.id); pending.delete(message.id); message.error ? p.reject(new Error(JSON.stringify(message.error))) : p.resolve(message.result); }
    if (message.method === 'Runtime.exceptionThrown') exceptions.push(message.params.exceptionDetails);
    if (message.method === 'Network.requestWillBeSent') network.push(message.params.request.url);
  });
  const call = (method, params = {}, scoped = true) => new Promise((resolve, reject) => {
    const id = ++serial; pending.set(id, { resolve, reject }); ws.send(JSON.stringify({ id, method, params, ...(scoped && session ? { sessionId: session } : {}) }));
  });
  const evaluate = async expression => {
    const r = await call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
    return r.result.value;
  };
  const wait = async expression => {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) { if (await evaluate(expression)) return; await new Promise(r => setTimeout(r, 50)); }
    throw new Error(`Timed out: ${expression}; status=${await evaluate('document.body.innerText')}`);
  };
  const click = text => evaluate(`Array.from(document.querySelectorAll('button')).find(b => b.textContent.trim() === ${JSON.stringify(text)})?.click()`);
  const source = value => evaluate(`window.editorModel().setValue(${JSON.stringify(value)})`);
  const toggle = async enabled => {
    await click('Settings'); await wait('!!document.getElementById("inline-code-checks")');
    if (await evaluate('document.getElementById("inline-code-checks").checked') !== enabled) {
      await evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))');
      await evaluate('document.getElementById("inline-code-checks").focus()');
      await call('Input.dispatchKeyEvent', { type: 'keyDown', key: ' ', code: 'Space', windowsVirtualKeyCode: 32 });
      await call('Input.dispatchKeyEvent', { type: 'keyUp', key: ' ', code: 'Space', windowsVirtualKeyCode: 32 });
      await wait(`document.getElementById('inline-code-checks').checked === ${enabled}`);
    }
    await evaluate(`document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))`);
    await wait('!document.getElementById("inline-code-checks")');
  };
  try {
    const target = (await call('Target.createTarget', { url: 'about:blank' }, false)).targetId;
    session = (await call('Target.attachToTarget', { targetId: target, flatten: true }, false)).sessionId;
    await call('Page.enable'); await call('Runtime.enable'); await call('Network.enable');
    await call('Page.addScriptToEvaluateOnNewDocument', { source: `(${fixture.toString()})()` });
    await call('Page.navigate', { url: `${origin}/problems/991` });
    await wait('!!window.editorModel?.()');
    assert.equal(await evaluate('fixture.workers.length'), 0);
    assert.equal(await evaluate('performance.getEntriesByType("resource").some(r=>r.name.includes("editor-diagnostics"))'), false);
    assert.deepEqual(await evaluate('inlineMarkers()'), []);
    await source('int solve( bad');
    await evaluate('new Promise(r=>setTimeout(r,600))');
    assert.equal(await evaluate('fixture.workers.length'), 0);
    await toggle(true);
    await wait('inlineMarkers().length > 0');
    assert.equal(await evaluate('fixture.workers.filter(w=>!w.terminated).length'), 1);
    const cpp = 'int solve(int x) { return x; }';
    await source(cpp); await wait('inlineMarkers().length === 0 && fixture.messages.at(-1)?.markers?.length === 0');
    assert.equal(await evaluate('fixture.requests.filter(r=>r.path.startsWith("/run/")).length'), 0);
    await source('int solve(int x) { /*😀é*/ return @; }'); await wait('inlineMarkers().length > 0');
    assert.equal(await evaluate('inlineMarkers().some(m=>m.range.startColumn === editorModel().getValue().indexOf("@")+1)'), true);
    milestones.push(await evaluate('({phase:"C++ real grammar",workers:fixture.workers,messages:fixture.messages,markers:inlineMarkers()})'));
    const syntaxImage = await call('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(path.join(output, 'cpp-syntax.png'), Buffer.from(syntaxImage.data, 'base64'));
    await source(cpp);
    await evaluate(`{const s=document.querySelector('[aria-label="Submission language"]');const set=Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set;set.call(s,'rust');s.dispatchEvent(new Event('change',{bubbles:true}));}`);
    await wait('window.editorModel()?.getLanguageId() === "rust" && fixture.messages.at(-1)?.language === "rust"');
    await source('pub fn solve(x: i32) -> i32 { /*😀*/ let y = @; x }'); await wait('inlineMarkers().length > 0');
    await source('pub fn solve(x: i32) -> i32 { println!("hi"); x }'); await wait('inlineMarkers().length === 0 && fixture.messages.at(-1)?.markers?.length === 0');
    assert.equal(await evaluate('fixture.workers.filter(w=>!w.terminated).length'), 1);
    milestones.push(await evaluate('({phase:"Rust real grammar",workers:fixture.workers,messages:fixture.messages})'));
    await toggle(false); assert.deepEqual(await evaluate('inlineMarkers()'), []);
    assert.equal(await evaluate('fixture.workers.filter(w=>!w.terminated).length'), 0);
    await call('Page.reload'); await wait('!!window.editorModel?.()');
    assert.equal(await evaluate('fixture.workers.length'), 0);
    await toggle(true); await wait('fixture.messages.length > 0');
    await call('Page.reload'); await wait('fixture.messages?.length > 0');
    assert.equal(await evaluate('JSON.parse(localStorage.data).state.inlineCodeChecks'), true);
    // Simulated compiler payloads exercise the actual buttons/job monitor/result panels.
    await source('pub fn solve(x: i32) -> i32 { x }');
    const payload = JSON.stringify([{ line: 1, col: 8, diagnostic_type: 'Error', message: 'SIMULATED compiler error' }, { line: 0, col: 0, diagnostic_type: 'Error', message: 'SIMULATED wrapper error' }]);
    await evaluate(`fixture.nextError=${JSON.stringify(payload)}`);
    await click('Show console'); await wait('Array.from(document.querySelectorAll("button")).some(b=>b.textContent.trim()==="Run")');
    await evaluate(`fixture.nextError=JSON.stringify(Array(5000).fill({line:1,col:1,diagnostic_type:'Error',message:'SIMULATED repeated diagnostic'}))`);
    await click('Run'); await wait('document.body.innerText.includes("4500 additional diagnostics omitted")');
    assert.equal(await evaluate('Array.from(document.querySelectorAll("code")).filter(e=>e.textContent === "SIMULATED repeated diagnostic").length'), 500);
    assert.ok(await evaluate('inlineMarkers().filter(m=>m.className === "squiggly-error").length <= 100'));
    milestones.push({ phase: 'Simulated compiler panel cap', diagnostics: 500, omitted: 4500 });
    await evaluate(`fixture.nextError=${JSON.stringify(payload)}`);
    await click('Run'); await wait('inlineMarkers().some(m=>m.className === "squiggly-error" && m.range.startColumn === 8)');
    assert.equal(await evaluate('inlineMarkers().find(m=>m.className === "squiggly-error").range.startColumn'), 8);
    assert.equal(await evaluate('document.body.innerText.includes("SIMULATED wrapper error")'), true);
    const screenshot = await call('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(path.join(output, 'compiler-simulated.png'), Buffer.from(screenshot.data, 'base64'));
    await toggle(false);
    assert.equal(await evaluate('document.body.innerText.includes("SIMULATED wrapper error")'), true);
    await evaluate('fixture.beforeOffRun=fixture.jobs.length'); await click('Run');
    await wait('fixture.jobs.length > fixture.beforeOffRun && fixture.jobs.at(-1).finished');
    assert.deepEqual(await evaluate('inlineMarkers()'), []);
    assert.equal(await evaluate('fixture.workers.filter(w=>!w.terminated).length'), 0);
    await toggle(true); await wait('fixture.messages.at(-1)?.version === editorModel().getVersionId()');
    assert.equal(await evaluate('inlineMarkers().some(m=>m.className === "squiggly-error")'), false);
    await source('pub fn solve(x: i32) -> i32 { x + 0 }'); assert.equal(await evaluate('inlineMarkers().some(m=>m.className === "squiggly-error")'), false);
    await click('Submit'); await wait('inlineMarkers().some(m=>m.className === "squiggly-error")');
    milestones.push(await evaluate('({phase:"Simulated Submit error",markers:inlineMarkers(),jobs:fixture.jobs})'));
    await evaluate('document.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}))');
    await evaluate('fixture.deferred=true'); await click('Submit'); await wait('fixture.jobs.at(-1)?.release');
    await toggle(false); await toggle(true); await evaluate('fixture.jobs.at(-1).release()');
    await wait('Array.from(document.querySelectorAll("button")).some(b=>b.textContent.trim()==="Submit" && !b.disabled)');
    assert.equal(await evaluate('inlineMarkers().some(m=>m.className === "squiggly-error")'), false);
    // Actual history restoration invalidates even identical source; old compiler response cannot return.
    await evaluate('fixture.historySource=editorModel().getValue(); fixture.historyLanguage="rust"');
    await click('Run'); await wait('fixture.jobs.at(-1)?.release');
    await click('History'); await wait('Array.from(document.querySelectorAll("button")).some(b=>b.textContent.trim()==="Load")');
    await click('Load'); await wait('fixture.requests.some(r=>r.path==="/submissions/91")');
    await evaluate('fixture.jobs.at(-1).release()');
    await evaluate('new Promise(r=>setTimeout(r,400))');
    assert.equal(await evaluate('inlineMarkers().some(m=>m.className === "squiggly-error")'), false);
    // Concurrent Run/Submit: newer successful compilation wins over older failure.
    await click('Run'); await wait('fixture.jobs.at(-1)?.release');
    await evaluate('fixture.oldJob=fixture.jobs.at(-1);fixture.nextError=null;fixture.deferred=false');
    await click('Submit'); await wait('fixture.jobs.at(-1)?.path === "/run/submit"');
    await evaluate('fixture.oldJob.release()'); await evaluate('new Promise(r=>setTimeout(r,400))');
    assert.equal(await evaluate('inlineMarkers().some(m=>m.className === "squiggly-error")'), false);
    // Real failed worker URL; editor and Run remain usable, resource ceiling stops workers.
    await toggle(false); await evaluate('fixture.failAssets=true'); await toggle(true);
    await wait('document.body.innerText.includes("Syntax checks unavailable")');
    await source('pub fn solve(x: i32) -> i32 { x + 1 }');
    await toggle(false); await evaluate('fixture.failAssets=false'); await toggle(true); await wait('fixture.workers.some(w=>!w.terminated)');
    await source('//'+ 'x'.repeat(201 * 1024)); await wait('document.body.innerText.includes("200 KiB")');
    assert.equal(await evaluate('fixture.workers.filter(w=>!w.terminated).length'), 0);
    await call('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: false });
    await source('pub fn solve(x: i32) -> i32 { x }');
    await wait('fixture.messages.at(-1)?.markers?.length === 0 && fixture.messages.at(-1)?.version === editorModel().getVersionId()');
    const narrow = await call('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(path.join(output, 'narrow.png'), Buffer.from(narrow.data, 'base64'));
    await toggle(false);
    await evaluate('window.next.router.push("/problems/992")');
    await wait('location.pathname === "/problems/992" && editorModel()?.getLanguageId() === "cpp"');
    assert.equal(await evaluate('fixture.workers.filter(w=>!w.terminated).length'), 0);
    assert.deepEqual(await evaluate('inlineMarkers()'), []);
    const result = await evaluate('({workers:fixture.workers,messages:fixture.messages,requests:fixture.requests})');
    fs.writeFileSync(path.join(output, 'ui-evidence.json'), JSON.stringify({ simulatedAPI: true, milestones, result, exceptions, network }, null, 2));
    // Explicit harness-only workers benchmark the same production assets after the UI is off.
    const benchmark = await evaluate(`(async () => {
      const results = [];
      for (const language of ['cpp','rust']) {
        const worker = new Worker('/editor-diagnostics/worker.js', {type:'module'});
        let id = 0;
        const parse = source => new Promise((resolve,reject) => {
          const timer=setTimeout(()=>reject(new Error('benchmark worker timeout')),10000);
          worker.onmessage=({data})=>{clearTimeout(timer);resolve(data)};
          worker.onerror=()=>{clearTimeout(timer);reject(new Error('benchmark worker failed'))};
          worker.postMessage({source,language,id:++id,editor:99,session:99,revision:id,version:id});
        });
        try {
          const valid=language==='cpp' ? '#define X 1\\r\\nint solve(int x) { /*😀é*/ return x + X; }' : 'pub fn solve(x: i32) -> i32 { /*😀é*/ println!("hi"); x }';
          const cold=await parse(valid), warm=[];
          for(let i=0;i<5;i++) warm.push(await parse(valid));
          const large=await parse(valid+'\\n//'+'x'.repeat(50*1024));
          const missing=await parse(valid.slice(0,-1));
          const incomplete=await parse(language==='cpp'?'int solve(':'pub fn solve(');
          const noisy=await parse((language==='cpp'?'int f(){ return @; }\\n':'fn f(){ let x = @; }\\n').repeat(150));
          results.push({language,cold,warm,large,missing,incomplete,noisy});
        } finally { worker.terminate(); }
      }
      return results;
    })()`);
    for (const r of benchmark) {
      for (const parsed of [r.cold,...r.warm,r.large]) { assert.equal(parsed.error, undefined); assert.deepEqual(parsed.markers, []); }
      assert.ok(r.missing.markers.length > 0); assert.ok(r.incomplete.markers.length > 0);
      assert.equal(r.noisy.markers.length, 100);
    }
    fs.writeFileSync(path.join(output, 'grammar-timings.json'), JSON.stringify(benchmark, null, 2));
    assert.equal(exceptions.length, 0, JSON.stringify(exceptions));
    console.log('PASS: real C++/Rust grammar UI; off/no assets; persistence; Unicode; simulated Run/Submit; history/off-on/concurrent stale rejection; missing worker; 200 KiB; teardown; narrow screen.');
    await call('Target.closeTarget', { targetId: target }, false);
  } finally { ws.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
