#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v node >/dev/null 2>&1; then
  echo 'SKIP: node not found — mods observer unit tests NOT run' >&2
  exit 0
fi

node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
const root = 'mods/orch-spawn-observer';
const read = path => readFileSync(path, 'utf8');
assert.equal(JSON.parse(read(`${root}/.claude-plugin/plugin.json`)).name, 'orch-spawn-observer');
const hooks = JSON.parse(read(`${root}/hooks/hooks.json`));
assert.deepEqual(hooks.modules, ['./register.mjs']);
assert.ok(existsSync(resolve(root, 'hooks', hooks.modules[0])));
assert.match(read(`${root}/hooks/register.mjs`), /export (?:const|function) register\b/);
function checkEngineStructure(source) {
  const expectedHooks = {
    'agent.spawn': 'agentSpawn', 'turn.step': 'turnStep',
    'session.start': 'sessionStart', 'session.end': 'sessionEnd',
  };
  // Remove only the permitted hook parameters before checking for bare API objects.
  let withoutParameters = source;
  for (const [event, name] of Object.entries(expectedHooks)) {
    const declaration = new RegExp(`^export async function${event === 'turn.step' ? '\\*' : ''} ${name}\\(\\$, e, next\\)`, 'm');
    assert.match(source, declaration, `${name} must be a top-level function declaration`);
    withoutParameters = withoutParameters.replace(declaration, declarationText => declarationText.replace('$', '_'));
  }
  const catchDeclaration = /^const passThrough = \(\$, e, next\) => next\(e\);/m;
  assert.match(source, catchDeclaration, 'catch handler must be a top-level const');
  withoutParameters = withoutParameters.replace(catchDeclaration, text => text.replace('$', '_'));
  // Template interpolation starts with ${; it does not read the API object itself.
  assert.doesNotMatch(withoutParameters, /\$(?!\.|\{)/, 'bare $ may only be a hook parameter');
  const calls = [...source.matchAll(/\bon\s*\(/g)];
  assert.equal(calls.length, 4);
  const seen = [];
  for (const call of calls) {
    const registration = /^on\s*\(\s*(['"])([^'"]+)\1\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)/.exec(source.slice(call.index));
    assert.ok(registration, 'on second argument must be a bare identifier');
    assert.equal(registration[3], expectedHooks[registration[2]]);
    seen.push(registration[2]);
  }
  assert.deepEqual(seen.sort(), Object.keys(expectedHooks).sort());
}
const moduleSource = read(`${root}/hooks/register.mjs`);
checkEngineStructure(moduleSource);
// These regressions must be rejected without needing the Claude CLI.
assert.throws(() => checkEngineStructure(moduleSource.replace("on('agent.spawn', agentSpawn)", "on('agent.spawn', hooks['agent.spawn'])")));
for (const forbidden of ['helper($);', 'const alias = $;', 'const copy = { ...$ };', 'return $;']) {
  assert.throws(() => checkEngineStructure(`${moduleSource}\n${forbidden}`));
}
for (const dir of ['hooks', 'lib']) {
  for (const file of readdirSync(`${root}/${dir}`).filter(name => name.endsWith('.mjs'))) {
    const source = read(`${root}/${dir}/${file}`);
    assert.doesNotMatch(source, /\b(?:import|require)\s*\(/);
    assert.doesNotMatch(source, /\bdeny\s*:/);
  }
}
const readme = read(`${root}/README.md`);
for (const text of ['--plugin-dir', 'spawn-observer.jsonl']) assert.ok(readme.includes(text));
assert.match(readme, /^## Removal/m);
for (const path of ['install.sh', 'guardrails.json']) assert.ok(!read(path).includes('orch-spawn-observer'));
console.log('PASS: mods observer structure');
JS

node --test mods/orch-spawn-observer/tests/observer-core.test.mjs mods/orch-spawn-observer/tests/observe-only.test.mjs

if [[ "${MODS_OBSERVER_CLAUDE:-0}" == 1 ]] && command -v claude >/dev/null 2>&1; then
  claude plugin validate mods/orch-spawn-observer
  claude plugin test mods/orch-spawn-observer
else
  echo 'NOTE: claude plugin validate/test not run (set MODS_OBSERVER_CLAUDE=1)'
fi
echo 'PASS: mods observer'
