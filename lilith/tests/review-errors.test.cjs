// Execute the real rejection branches with HTTP responses; not browser tests.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const ts = require('typescript');
const vm = require('node:vm');

function sourceNode(file, matches) {
  const tree = ts.createSourceFile(file, readFileSync(path.join(__dirname, '..', file), 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const found = [];
  function visit(node) {
    if (matches(node)) found.push(node.getText(tree));
    ts.forEachChild(node, visit);
  }
  visit(tree);
  assert.equal(found.length, 1);
  return found[0];
}

const bodies = [['<html>Unavailable</html>', null], ['', null], ['null', null], ['{}', null], ['{"message":"Denied"}', 'Denied'], ['{"error":"Denied"}', 'Denied']];
for (const [file, fallback] of [['code-runner.tsx', 'Submission was rejected.'], ['input-tester.tsx', 'Custom input was rejected.']]) {
  test(`${file} handles malformed and JSON rejection bodies`, async () => {
    const branch = sourceNode(`components/problem/${file}`, n => ts.isIfStatement(n) && n.expression.getText() === '!res.ok');
    const code = ts.transpileModule(`(async () => { ${branch} })()`, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
    for (const [body, message] of bodies) {
      let error;
      let result = { old: true };
      await vm.runInNewContext(code, {
        res: new Response(body, { status: 502 }),
        setError: value => { error = value; },
        setResultError: value => { error = value; },
        setTestResult: value => { result = value; },
      });
      assert.equal(error, message ?? fallback);
      if (file === 'input-tester.tsx') assert.equal(result, null);
    }
  });
}

test('Rust template errors have a fallback, and successful templates are unchanged', async () => {
  const fn = sourceNode('components/problem/index.tsx', n => ts.isFunctionDeclaration(n) && n.name?.text === 'rustTemplate');
  const code = ts.transpileModule(`${fn}; rustTemplate('http://test.invalid')`, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
  for (const [body, message] of bodies) {
    await assert.rejects(vm.runInNewContext(code, { fetch: async () => new Response(body, { status: 502 }) }), error => error.message === (message ?? 'Could not load the Rust template.'));
  }
  assert.equal(await vm.runInNewContext(code, { fetch: async () => new Response(JSON.stringify('fn add() {}')) }), 'fn add() {}');
});
