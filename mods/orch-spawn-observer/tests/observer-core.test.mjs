import test from 'node:test';
import assert from 'node:assert/strict';
import {
  OBSERVER_VERSION, MIN_HOST_VERSION, PENDING_CAP, LOG_MAX_BYTES, LOG_KEEP_BYTES,
  isManagedTypeName, profilePath, parseProfile, modelFamily, normalizeModel, modelsEquivalent,
  normalizeEffort, expectationFromProfile, compare, buildRecord, appendJsonl,
  PendingSpawns, EarlySteps, versionAtLeast, stateLogPath, configDir,
} from '../lib/observer-core.mjs';

const pinned = { profile: 'found', expected_model: 'opus[1m]', expected_effort: 'high' };
const comparePinned = overrides => compare({
  expectation: pinned, effectiveModel: 'claude-opus-5-5', effectiveEffort: 'high',
  effortObserved: true, ...overrides,
});
const fromText = text => expectationFromProfile({ agentType: 'lead-charlie', lookup: { kind: 'text', text } });

test('policy constants', () => {
  assert.deepEqual([OBSERVER_VERSION, MIN_HOST_VERSION, PENDING_CAP, LOG_MAX_BYTES, LOG_KEEP_BYTES],
    ['0.1.0', '2.1.287', 64, 1048576, 524288]);
});

test('match', () => assert.deepEqual(comparePinned(), { verdict: 'match', reasons: [] }));

test('model mismatch', () => {
  assert.deepEqual(comparePinned({ effectiveModel: 'claude-sonnet-5-5' }), {
    verdict: 'mismatch', reasons: ['model: expected opus[1m] got claude-sonnet-5-5'],
  });
});

test('effort mismatch', () => {
  assert.deepEqual(comparePinned({ effectiveEffort: 'medium' }), {
    verdict: 'mismatch', reasons: ['effort: expected high got medium'],
  });
});

test('alias and family equivalence, including inherit', () => {
  assert.equal(modelsEquivalent('opus[1m]', 'claude-opus-5-5'), true);
  assert.equal(modelsEquivalent('sonnet[1m]', 'claude-sonnet-5-5'), true);
  assert.equal(modelsEquivalent(' Custom[32k] ', 'custom'), true);
  assert.equal(modelsEquivalent('custom', 'different'), false);
  assert.equal(modelsEquivalent(null, 'opus'), null);
  assert.equal(modelsEquivalent('opus', ' '), null);
  assert.equal(normalizeModel(' Opus[1m] '), 'opus');
  assert.equal(modelFamily('SONNET-OPUS-FABLE-haiku'), 'fable');
  assert.equal(modelFamily('OPUS-sonnet'), 'opus');
  assert.equal(modelFamily('haiku'), 'haiku');
  assert.equal(modelFamily('custom[opus]'), 'opus');
  assert.equal(modelFamily('custom'), null);
  const expectation = expectationFromProfile({
    agentType: 'dev-1', parentModel: 'claude-sonnet-5-5',
    lookup: { kind: 'text', text: '---\nmodel: inherit\neffort: high\n---\n' },
  });
  assert.equal(expectation.model_inherit, true);
  assert.equal(expectation.expected_model, 'claude-sonnet-5-5');
  assert.equal(comparePinned({ expectation, effectiveModel: 'sonnet[1m]' }).verdict, 'match');
});

test('unmanaged agent names never form a profile path', () => {
  for (const name of ['plugin:agent', '../dev-1', 'a/b', '..', '', 'a'.repeat(65), null, 'a\n']) {
    assert.equal(isManagedTypeName(name), false);
    assert.equal(profilePath('/config', name), null);
  }
  assert.equal(isManagedTypeName('route-lead_alpha-1'), true);
  assert.equal(isManagedTypeName('a'.repeat(64)), true);
  assert.equal(profilePath('/config/', 'dev-1'), '/config/agents/dev-1.md');
  for (const lookup of [{ kind: 'unmanaged-name' }, { kind: 'missing' }]) {
    const expectation = expectationFromProfile({ agentType: 'plugin:agent', lookup });
    assert.equal(expectation.profile, 'unmanaged-name');
    assert.equal(comparePinned({ expectation }).verdict, 'unmanaged');
  }
});

test('missing profile file is unmanaged', () => {
  const expectation = expectationFromProfile({ agentType: 'dev-1', lookup: { kind: 'missing' } });
  assert.deepEqual(expectation, { profile: 'missing', expected_model: null, expected_effort: null });
  assert.equal(comparePinned({ expectation }).verdict, 'unmanaged');
});

test('malformed frontmatter without opening delimiter is unknown', () => {
  const expectation = fromText('model: opus\neffort: high\n---\n');
  assert.equal(expectation.profile, 'malformed');
  assert.deepEqual(comparePinned({ expectation }), { verdict: 'unknown', reasons: ['profile malformed'] });
});

test('malformed frontmatter without closing delimiter is unknown', () => {
  assert.equal(comparePinned({ expectation: fromText('---\nmodel: opus\n') }).verdict, 'unknown');
  assert.equal(parseProfile('--- \nmodel: opus\n---').status, 'malformed');
});

test('unreadable profile is unknown', () => {
  const expectation = expectationFromProfile({ agentType: 'dev-1', lookup: { kind: 'unreadable', reason: 'unavailable' } });
  assert.equal(expectation.reason, 'unavailable');
  assert.deepEqual(comparePinned({ expectation }), { verdict: 'unknown', reasons: ['profile unreadable'] });
});

test('only indented keys pin nothing', () => {
  const expectation = fromText('---\nhooks:\n  model: opus\n\teffort: high\n---\nmodel: sonnet');
  assert.deepEqual(comparePinned({ expectation }), { verdict: 'unmanaged', reasons: ['profile pins nothing'] });
});

test('profile parser handles BOM, CRLF, quotes, empty values, and first duplicate wins', () => {
  assert.deepEqual(parseProfile('\uFEFF---\r\nmodel: "opus[1m]"\r\neffort: \'high\'\r\nmodel: sonnet\r\n---\r\n'),
    { status: 'ok', model: 'opus[1m]', effort: 'high' });
  assert.deepEqual(parseProfile('---\nmodel: \neffort: ""\nmodel: opus\n---'),
    { status: 'ok', model: null, effort: null });
  assert.equal(parseProfile(null).status, 'malformed');
});

test('effort not observed is unknown', () => {
  for (const overrides of [{ effortObserved: false }, { effectiveEffort: undefined }]) {
    assert.deepEqual(comparePinned(overrides), { verdict: 'unknown', reasons: ['effort not observed'] });
  }
});

test('missing effective model is unknown', () => {
  assert.deepEqual(comparePinned({ effectiveModel: null }), { verdict: 'unknown', reasons: ['model not observed'] });
});

test('mismatch outranks unknown', () => {
  assert.deepEqual(comparePinned({ effectiveModel: 'sonnet', effortObserved: false }), {
    verdict: 'mismatch', reasons: ['model: expected opus[1m] got sonnet', 'effort not observed'],
  });
});

test('effort normalizes strings and numbers', () => {
  assert.equal(normalizeEffort(' HIGH '), 'high');
  assert.equal(normalizeEffort(0), '0');
  assert.equal(normalizeEffort(undefined), null);
  assert.equal(normalizeEffort(''), null);
  assert.equal(comparePinned({ effectiveEffort: ' HIGH ' }).verdict, 'match');
});

test('buildRecord has an exact ordered allowlist and truncates every string', () => {
  const secret = 'secret-prompt-never-log';
  const record = buildRecord({
    expectation: pinned, ts: '2026-10-07T00:00:00.000Z', hostVersion: '2.1.292', sessionId: 's1',
    agentId: 'a1', agentType: 'lead-charlie', parentModel: 'opus', requestedModel: 'opus[1m]',
    requestedEffort: secret, spawnModel: 'opus', stepModel: 'claude-opus-5-5',
    answeredModel: 'claude-opus-5-5', stepEffort: 'high', effortObserved: true,
    fork: true, teammate: true, source: 'agent.spawn+turn.step', denied: false,
    prompt: secret, description: secret, cwd: secret, name: secret, tool_use_id: secret,
    deny: secret, HOME: secret, answer: secret,
  });
  assert.deepEqual(Object.keys(record), [
    'ts', 'observer', 'host_version', 'session_id', 'agent_id', 'agent_type', 'fork', 'teammate',
    'parent_model', 'requested_model', 'requested_effort', 'effective_model', 'step_model',
    'answered_model', 'step_effort', 'effort_source', 'effort_observed', 'expected_model',
    'expected_effort', 'profile', 'verdict', 'reasons', 'source', 'denied',
  ]);
  assert.equal(Object.getPrototypeOf(record), Object.prototype);
  assert.equal(JSON.stringify(record).includes(secret), false);
  assert.equal(record.requested_effort, null);
  assert.equal(record.step_effort, 'high');
  assert.equal(record.effort_source, 'turn.step-input');
  assert.equal(record.verdict, 'match');
  assert.equal(record.fork, true);
  assert.equal(record.teammate, true);
  const long = 'x'.repeat(300);
  const truncated = buildRecord({
    expectation: { profile: long, expected_model: long, expected_effort: long },
    ts: long, hostVersion: long, sessionId: long, agentId: long, agentType: long,
    parentModel: long, requestedModel: long, spawnModel: long, stepModel: long,
    answeredModel: long, stepEffort: long, effortObserved: true, source: long,
  });
  for (const value of Object.values(truncated).flat()) {
    if (typeof value === 'string') assert.ok(value.length <= 200);
  }
  assert.equal(truncated.agent_type.length, 200);
  assert.equal(truncated.teammate, null);
});

test('record uses answered model, then step input, then spawn model', () => {
  const fields = { expectation: pinned, spawnModel: 'opus', stepModel: 'claude-opus-5-5', effortObserved: true, stepEffort: 'high' };
  const answered = buildRecord({ ...fields, answeredModel: 'claude-sonnet-5-5' });
  assert.equal(answered.effective_model, 'claude-sonnet-5-5');
  assert.equal(answered.verdict, 'mismatch');
  assert.equal(buildRecord(fields).effective_model, 'claude-opus-5-5');
  const unobserved = buildRecord({ ...fields, effortObserved: false });
  assert.equal(unobserved.effective_model, 'opus');
  assert.equal(unobserved.step_model, null);
  assert.equal(unobserved.answered_model, null);
  assert.equal(unobserved.step_effort, null);
  assert.equal(unobserved.effort_source, null);
  assert.equal(unobserved.verdict, 'unknown');
  assert.match(unobserved.ts, /^\d{4}-\d\d-\d\dT/);
});

test('appendJsonl adds a missing newline and drops only whole UTF-8 lines', () => {
  assert.equal(appendJsonl('{"old":true}', [{ new: true }]), '{"old":true}\n{"new":true}\n');
  const records = [{ value: '한😀' }, { value: 'é' }, { value: 'last' }];
  const full = records.map(record => `${JSON.stringify(record)}\n`).join('');
  const lastTwo = records.slice(1).map(record => `${JSON.stringify(record)}\n`).join('');
  const keepBytes = Buffer.byteLength(lastTwo);
  assert.equal(appendJsonl('', records, { maxBytes: Buffer.byteLength(full) - 1, keepBytes }), lastTwo);
  assert.equal(appendJsonl('', records, { maxBytes: Buffer.byteLength(full), keepBytes }), full);
  assert.equal(appendJsonl('', [{ oversized: '한'.repeat(20) }], { maxBytes: 20, keepBytes: 10 }), '');
});

test('PendingSpawns bounds eviction order, take and drain', () => {
  const pending = new PendingSpawns(2);
  assert.deepEqual(pending.add('a', { id: 'a' }), []);
  pending.add('b', { id: 'b' });
  assert.deepEqual(pending.add('c', { id: 'c' }), [{ id: 'a' }]);
  assert.equal(pending.size, 2);
  assert.equal(pending.has('a'), false);
  assert.deepEqual(pending.take('b'), { id: 'b' });
  assert.equal(pending.take('b'), undefined);
  pending.add('d', { id: 'd' });
  assert.deepEqual(pending.drain(), [{ id: 'c' }, { id: 'd' }]);
  assert.equal(pending.size, 0);
  assert.equal(new EarlySteps().cap, 64);
});

test('versionAtLeast accepts a leading version and leaves unknown versions alone', () => {
  for (const version of ['2.1.287', '2.1.292 (Claude Code)', '2.2.0', '3.0.0']) {
    assert.equal(versionAtLeast(version, MIN_HOST_VERSION), true);
  }
  for (const version of ['2.1.286', '2.0.999', '1.99.999']) {
    assert.equal(versionAtLeast(version, MIN_HOST_VERSION), false);
  }
  for (const version of ['unknown', 'v2.1.292', '2.1', undefined]) {
    assert.equal(versionAtLeast(version, MIN_HOST_VERSION), null);
  }
});

test('stateLogPath and configDir defaults and overrides', () => {
  assert.equal(stateLogPath({ HOME: '/home/fake' }), '/home/fake/.claude/orchestra-state/spawn-observer.jsonl');
  assert.equal(stateLogPath({ HOME: '/ignored', CC_ORCH_STATE_DIR: '/custom/' }), '/custom/spawn-observer.jsonl');
  assert.equal(stateLogPath({ CC_ORCH_STATE_DIR: '/custom' }), '/custom/spawn-observer.jsonl');
  assert.equal(stateLogPath({}), null);
  assert.equal(configDir({ HOME: '/home/fake/' }), '/home/fake/.claude');
  assert.equal(configDir({ CLAUDE_CONFIG_DIR: '/config' }), '/config');
  assert.equal(configDir({}), null);
});
