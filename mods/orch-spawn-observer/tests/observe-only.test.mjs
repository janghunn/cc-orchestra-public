import test from 'node:test';
import assert from 'node:assert/strict';
import { agentSpawn, turnStep, sessionStart, sessionEnd, register, __testing } from '../hooks/register.mjs';
import { PendingSpawns } from '../lib/observer-core.mjs';

const profilePath = '/home/fake/.claude/agents/lead-charlie.md';
const logPath = '/home/fake/.claude/orchestra-state/spawn-observer.jsonl';
const profile = '---\nname: lead-charlie\nmodel: opus[1m]\neffort: high\n---\n';
const events = ['agent.spawn', 'turn.step', 'session.start', 'session.end'];
const expectation = { profile: 'found', expected_model: 'opus[1m]', expected_effort: 'high' };

const exportedHooks = {
  'agent.spawn': agentSpawn, 'turn.step': turnStep,
  'session.start': sessionStart, 'session.end': sessionEnd,
};

function freshObserver({ core = {} } = {}) {
  __testing.reset();
  __testing.setCore(core);
  return { hooks: exportedHooks, state: __testing.state };
}

function fixture(env = {}) {
  const files = new Map([[profilePath, profile]]);
  const writes = [];
  const reads = [];
  const logs = [];
  const calls = [];
  const $ = {
    env: { get: async name => { calls.push(`env.${name}`); return ({ HOME: '/home/fake', ...env })[name]; } },
    fs: {
      exists: async path => { calls.push('fs.exists'); return files.has(path); },
      read: async path => {
        calls.push('fs.read'); reads.push(path);
        if (!files.has(path)) throw new Error('ENOENT');
        return files.get(path);
      },
      write: async (path, text) => { calls.push('fs.write'); writes.push({ path, text }); files.set(path, text); },
    },
    session: {
      id: async () => { calls.push('session.id'); return 's1'; },
      version: async () => { calls.push('session.version'); return { version: '2.1.292', base: '2.1.292' }; },
    },
    ui: { log: async (message, options) => { calls.push('ui.log'); logs.push({ message, options }); } },
  };
  return { $, files, writes, reads, logs, calls, records: (path = logPath) =>
    (files.get(path) ?? '').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)) };
}

function freeze(value) {
  if (value && typeof value === 'object') {
    for (const child of Object.values(value)) freeze(child);
    Object.freeze(value);
  }
  return value;
}

function eventInput(event, id = 'a1') {
  if (event === 'agent.spawn') return {
    subagentType: 'lead-charlie', model: 'opus[1m]', parentModel: 'opus', fork: false,
    prompt: 'secret-prompt', description: 'secret-description', cwd: '/secret/path',
    name: 'secret-name', tool_use_id: 'secret-tool-id', extra: { nested: ['frozen'] },
  };
  if (event === 'turn.step') return { agentId: id, model: 'claude-opus-5-5', effort: 'high', index: 0 };
  return { reason: 'fixture', extra: { nested: ['frozen'] } };
}

function seedPending(observer, id = 'a1') {
  observer.state.pending.add(id, {
    agentId: id, agentType: 'lead-charlie', spawnModel: 'claude-opus-5-5',
    expectationP: Promise.resolve(expectation),
  });
}

async function drain(stream) {
  const chunks = [];
  while (true) {
    const item = await stream.next();
    if (item.done) return { result: item.value, chunks };
    chunks.push(item.value);
  }
}

async function spawn(observer, f, id = 'a1', input = {}, result = {}) {
  const e = freeze({ ...eventInput('agent.spawn'), ...input });
  const answer = freeze({ model: 'claude-opus-5-5', agentId: id, ...result });
  assert.equal(await observer.hooks['agent.spawn'](f.$, e, async received => {
    assert.equal(received, e); return answer;
  }), answer);
}

async function step(observer, f, id = 'a1', input = {}, result = {}) {
  const e = freeze({ ...eventInput('turn.step', id), ...input });
  const answer = freeze({ usage: { model: 'claude-opus-5-5' }, ...result });
  const chunk = freeze({ kind: 'text', text: 'private-answer' });
  const output = await drain(observer.hooks['turn.step'](f.$, e, async function* (received) {
    assert.equal(received, e); yield chunk; return answer;
  }));
  assert.equal(output.result, answer);
  assert.equal(output.chunks[0], chunk);
}

function registrations(rejectEvent) {
  __testing.reset();
  const hooks = {};
  const catches = {};
  register((event, hook) => {
    if (event === rejectEvent) throw new Error('unsupported event');
    hooks[event] = hook;
    return { catch(handler) { catches[event] = handler; } };
  }, {});
  return { hooks, catches };
}

test('registers exactly the four specified events with non-streaming catches only', async () => {
  const { hooks, catches } = registrations();
  assert.deepEqual(Object.keys(hooks).sort(), [...events].sort());
  for (const event of events) assert.equal(hooks[event], exportedHooks[event]);
  assert.deepEqual(Object.keys(catches).sort(), events.filter(event => event !== 'turn.step').sort());
  for (const handler of Object.values(catches)) {
    const e = freeze({ extra: { nested: true } });
    const result = {};
    const promise = Promise.resolve(result);
    let calls = 0;
    assert.equal(handler({}, e, received => { calls++; assert.equal(received, e); return promise; }), promise);
    assert.equal(calls, 1);
    assert.equal(await promise, result);
  }
});

for (const event of events) {
  for (const mode of ['registered', 'throwing APIs', 'rejecting APIs', 'throwing core']) {
    test(`${event}: identity and exactly one next with ${mode}`, async () => {
      const f = fixture();
      let coreCalls = 0;
      const fail = () => { coreCalls++; throw new Error('core failed'); };
      const observer = mode === 'registered' ? registrations() : freshObserver(mode === 'throwing core' ? {
        core: { isManagedTypeName: fail, buildRecord: fail, versionAtLeast: fail },
      } : {});
      if (observer.state && (event === 'turn.step' || event === 'session.end')) seedPending(observer);
      if (mode.includes('APIs')) {
        for (const namespace of Object.values(f.$)) {
          for (const key of Object.keys(namespace)) {
            namespace[key] = mode === 'throwing APIs'
              ? () => { throw new Error('API unavailable'); }
              : async () => { throw new Error('API unavailable'); };
          }
        }
      }
      const e = freeze(eventInput(event));
      const before = JSON.stringify(e);
      const answer = freeze({ model: 'claude-opus-5-5', usage: { model: 'claude-opus-5-5' } });
      const chunks = [freeze({ kind: 'text', text: 'first' }), freeze({ kind: 'text', text: 'second' })];
      let calls = 0;
      const spy = received => { calls++; assert.equal(received, e); };
      let result;
      if (event === 'turn.step') {
        const output = await drain(observer.hooks[event](f.$, e, async function* (received) {
          spy(received); yield* chunks; return answer;
        }));
        result = output.result;
        assert.equal(output.chunks.length, chunks.length);
        output.chunks.forEach((chunk, index) => assert.equal(chunk, chunks[index]));
      } else {
        result = await observer.hooks[event](f.$, e, async received => { spy(received); return answer; });
      }
      assert.equal(calls, 1);
      assert.equal(result, answer);
      assert.equal(Object.hasOwn(result, 'deny'), false);
      assert.equal(JSON.stringify(e), before);
      if (mode === 'throwing core') assert.ok(coreCalls > 0, 'actually exercised a throwing core function');
    });
  }

  test(`${event}: next rejection propagates unchanged without replay`, async () => {
    const observer = freshObserver();
    const f = fixture();
    if (event === 'turn.step' || event === 'session.end') seedPending(observer);
    const e = freeze(eventInput(event));
    const before = JSON.stringify(e);
    const error = new Error('engine failure');
    let calls = 0;
    const fail = received => { calls++; assert.equal(received, e); throw error; };
    const run = event === 'turn.step'
      ? drain(observer.hooks[event](f.$, e, async function* (received) { fail(received); }))
      : observer.hooks[event](f.$, e, fail);
    await assert.rejects(run, received => received === error);
    assert.equal(calls, 1);
    assert.equal(JSON.stringify(e), before);
    if (event === 'turn.step') {
      assert.equal(f.records()[0].answered_model, null);
      assert.equal(f.records()[0].step_model, 'claude-opus-5-5');
    }
  });
}

test('unsupported spawn disables observation; remaining hooks pass through and debug once', async () => {
  const observer = registrations('agent.spawn');
  assert.deepEqual(Object.keys(observer.hooks).sort(), ['session.end', 'session.start', 'turn.step']);
  const f = fixture();
  const answer = freeze({ untouched: true });
  for (const event of ['session.start', 'session.start', 'turn.step', 'session.end']) {
    const e = freeze(eventInput(event));
    let calls = 0;
    const spy = received => { calls++; assert.equal(received, e); return answer; };
    const result = event === 'turn.step'
      ? (await drain(observer.hooks[event](f.$, e, async function* (received) { return spy(received); }))).result
      : await observer.hooks[event](f.$, e, spy);
    assert.equal(result, answer);
    assert.equal(calls, 1);
  }
  assert.deepEqual(f.calls, ['ui.log']);
  assert.deepEqual(f.logs, [{
    message: 'orch-spawn-observer: agent.spawn not offered by this host; observer disabled', options: { to: 'debug' },
  }]);
});

test('unsupported turn.step keeps spawning observable with unobserved effort', async () => {
  const observer = registrations('turn.step');
  const f = fixture();
  await spawn(observer, f);
  assert.equal(f.records()[0].source, 'agent.spawn');
  assert.equal(f.records()[0].effort_observed, false);
  assert.equal(f.records()[0].verdict, 'unknown');
});

test('each registration is guarded independently', () => {
  for (const event of ['session.start', 'session.end']) {
    assert.equal(Object.keys(registrations(event).hooks).length, 3);
  }
});

test('old host version disables all later observation and logs once', async () => {
  const observer = freshObserver();
  const f = fixture();
  f.$.session.version = async () => ({ version: '2.1.286-preview', base: '2.1.286' });
  await observer.hooks['session.start'](f.$, {}, async () => undefined);
  await observer.hooks['session.start'](f.$, {}, async () => undefined);
  const previousCalls = f.calls.length;
  await spawn(observer, f);
  await step(observer, f);
  await observer.hooks['session.end'](f.$, {}, async () => undefined);
  assert.equal(f.calls.length, previousCalls);
  assert.equal(f.logs.length, 1);
  assert.match(f.logs[0].message, /host older than 2\.1\.287/);
});

test('host version is cached once and unknown version strings do not disable', async () => {
  const observer = freshObserver();
  const f = fixture();
  let calls = 0;
  f.$.session.version = async () => { calls++; return { version: 'development build' }; };
  await observer.hooks['session.start'](f.$, {}, async () => undefined);
  await observer.hooks['session.start'](f.$, {}, async () => undefined);
  await spawn(observer, f);
  await step(observer, f);
  assert.equal(calls, 1);
  assert.equal(f.records()[0].host_version, 'development build');
});

test('spawn plus step writes one matching, private-data-free record to the default path', async () => {
  const observer = freshObserver();
  const f = fixture();
  await spawn(observer, f, 'a1', { fork: true, isTeammate: true });
  assert.equal(f.writes.length, 0);
  await step(observer, f);
  assert.equal(f.writes.length, 1);
  assert.equal(f.writes[0].path, logPath);
  const [record] = f.records();
  assert.equal(record.verdict, 'match');
  assert.equal(record.source, 'agent.spawn+turn.step');
  assert.equal(record.effort_source, 'turn.step-input');
  assert.equal(record.fork, true);
  assert.equal(record.teammate, true);
  assert.equal(record.session_id, 's1');
  assert.equal(record.agent_id, 'a1');
  assert.equal(f.writes[0].text.includes('secret'), false);
  assert.equal(f.writes[0].text.includes('private-answer'), false);
  assert.equal(f.writes[0].text.includes('/home/fake'), false);
});

test('CC_ORCH_STATE_DIR and CLAUDE_CONFIG_DIR override their defaults', async () => {
  const observer = freshObserver();
  const f = fixture({ CC_ORCH_STATE_DIR: '/state', CLAUDE_CONFIG_DIR: '/config' });
  f.files.set('/config/agents/lead-charlie.md', profile);
  await spawn(observer, f);
  await step(observer, f);
  assert.equal(f.writes[0].path, '/state/spawn-observer.jsonl');
  assert.equal(f.records('/state/spawn-observer.jsonl')[0].verdict, 'match');
  assert.deepEqual(f.reads, ['/config/agents/lead-charlie.md']);
});

test('no HOME or state override means no log write', async () => {
  const observer = freshObserver();
  const f = fixture({ HOME: undefined });
  await spawn(observer, f);
  await step(observer, f);
  assert.equal(f.writes.length, 0);
  assert.equal(f.logs.length, 0);
});

test('session.end flushes pending spawns in one write with effort unobserved', async () => {
  const observer = freshObserver();
  const f = fixture();
  await spawn(observer, f, 'a1');
  await spawn(observer, f, 'a2');
  const answer = {};
  assert.equal(await observer.hooks['session.end'](f.$, {}, async () => answer), answer);
  assert.equal(f.writes.length, 1);
  assert.equal(f.records().length, 2);
  for (const record of f.records()) {
    assert.equal(record.effort_observed, false);
    assert.equal(record.source, 'session.end');
    assert.equal(record.verdict, 'unknown');
  }
  assert.equal(observer.state.pending.size, 0);
});

test('unknown agent steps and main-loop steps perform no I/O; early buffer is bounded', async () => {
  const observer = freshObserver();
  const f = fixture();
  await step(observer, f, undefined, { agentId: undefined });
  assert.equal(observer.state.earlySteps.size, 0);
  for (let i = 0; i < 65; i++) await step(observer, f, `unknown-${i}`);
  assert.equal(observer.state.earlySteps.size, 64);
  assert.equal(observer.state.earlySteps.has('unknown-0'), false);
  assert.deepEqual(f.calls, []);
});

test('two concurrent spawns and steps retain both JSONL records', async () => {
  const observer = freshObserver();
  const f = fixture();
  const write = f.$.fs.write;
  f.$.fs.write = async (...args) => { await new Promise(resolve => setImmediate(resolve)); await write(...args); };
  await Promise.all([spawn(observer, f, 'a1'), spawn(observer, f, 'a2')]);
  await Promise.all([step(observer, f, 'a1'), step(observer, f, 'a2')]);
  assert.deepEqual(f.records().map(record => record.agent_id).sort(), ['a1', 'a2']);
  assert.equal(f.writes.length, 2);
});

test('a step during a suspended profile read is joined exactly once after spawn bookkeeping', async () => {
  const observer = freshObserver();
  const f = fixture();
  let releaseProfile;
  let profileStarted;
  const started = new Promise(resolve => { profileStarted = resolve; });
  const profileRead = new Promise(resolve => { releaseProfile = resolve; });
  f.$.fs.read = async path => {
    if (path === profilePath) { profileStarted(); return profileRead; }
    return f.files.get(path);
  };
  const answer = freeze({ model: 'claude-opus-5-5', agentId: 'a1' });
  let nextCalled = false;
  const spawning = observer.hooks['agent.spawn'](f.$, freeze(eventInput('agent.spawn')), async () => {
    nextCalled = true;
    await started;
    await step(observer, f, 'a1', { model: 'claude-sonnet-5-5', effort: 'medium' }, { usage: null });
    return answer;
  });
  assert.equal(nextCalled, true, 'profile lookup never delays next');
  await started;
  // Let next finish the early step while profile I/O remains suspended.
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.writes.length, 0);
  releaseProfile(profile);
  assert.equal(await spawning, answer);
  const records = f.records();
  assert.equal(records.length, 1);
  assert.equal(records[0].step_model, 'claude-sonnet-5-5');
  assert.equal(records[0].effective_model, 'claude-sonnet-5-5');
  assert.equal(records[0].step_effort, 'medium');
  assert.equal(records[0].effort_observed, true);
  assert.equal(records[0].verdict, 'mismatch');
  await step(observer, f, 'a1');
  assert.equal(f.writes.length, 1);
  assert.equal(observer.state.earlySteps.size, 0);
  assert.equal(observer.state.recorded.has('a1'), true);
});

test('an early step still streaming when spawn resolves retains the answering model', async () => {
  const observer = freshObserver();
  const f = fixture();
  let finish;
  const response = new Promise(resolve => { finish = resolve; });
  const streaming = drain(observer.hooks['turn.step'](f.$, eventInput('turn.step'), async function* () {
    yield { kind: 'text', text: 'private' };
    return await response;
  }));
  const spawning = spawn(observer, f);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.writes.length, 0);
  finish({ usage: { model: 'claude-sonnet-5-5' } });
  await Promise.all([streaming, spawning]);
  assert.equal(f.records()[0].answered_model, 'claude-sonnet-5-5');
  assert.equal(f.records()[0].verdict, 'mismatch');
});

test('spawn returns before an early stream ends and the handoff writes exactly once', async () => {
  const observer = freshObserver();
  const f = fixture();
  const input = freeze(eventInput('turn.step'));
  const chunk = freeze({ kind: 'text', text: 'private-answer' });
  const answer = freeze({ usage: { model: 'claude-sonnet-5-5' } });
  let finish;
  const response = new Promise(resolve => { finish = resolve; });
  let streamEnded = false;
  let spawnReturned = false;
  const streaming = drain(turnStep(f.$, input, async function* (received) {
    assert.equal(received, input);
    yield chunk;
    const result = await response;
    streamEnded = true;
    return result;
  }));
  const spawning = spawn(observer, f).then(() => { spawnReturned = true; });
  try {
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(spawnReturned, true, 'spawn must return while the first response is still open');
    assert.equal(streamEnded, false);
    assert.equal(f.writes.length, 0);
    assert.equal(observer.state.pending.size, 0);
    assert.equal(observer.state.earlySteps.size, 0);
    assert.equal(observer.state.recorded.has('a1'), true);
  } finally {
    finish(answer);
    await spawning;
    const output = await streaming;
    assert.equal(output.result, answer);
    assert.equal(output.chunks[0], chunk);
  }
  assert.equal(streamEnded, true);
  assert.equal(f.writes.length, 1);
  assert.equal(f.records().length, 1);
  assert.equal(f.records()[0].answered_model, 'claude-sonnet-5-5');
  assert.equal(f.records()[0].step_effort, 'high');
  assert.equal(f.records()[0].effort_observed, true);
  assert.equal(f.records()[0].verdict, 'mismatch');
  await step(observer, f);
  assert.equal(f.writes.length, 1);
  assert.equal(observer.state.earlySteps.size, 0);
});

test('answered model outranks step input for the verdict', async () => {
  const observer = freshObserver();
  const f = fixture();
  await spawn(observer, f);
  await step(observer, f, 'a1', {}, { usage: { model: 'claude-sonnet-5-5' } });
  const [record] = f.records();
  assert.equal(record.step_model, 'claude-opus-5-5');
  assert.equal(record.answered_model, 'claude-sonnet-5-5');
  assert.equal(record.effective_model, 'claude-sonnet-5-5');
  assert.equal(record.verdict, 'mismatch');
});

test('log read failure preserves every byte of an existing two-line log', async () => {
  const observer = freshObserver();
  const f = fixture();
  const original = '{"older":1}\n{"older":2}\n';
  f.files.set(logPath, original);
  const read = f.$.fs.read;
  f.$.fs.read = async path => { if (path === logPath) throw new Error('permission denied'); return read(path); };
  for (const id of ['a1', 'a2']) { await spawn(observer, f, id); await step(observer, f, id); }
  assert.equal(f.files.get(logPath), original);
  assert.equal(f.writes.length, 0);
  assert.deepEqual(f.logs, [{
    message: 'orch-spawn-observer: log write failed: permission denied', options: { to: 'debug' },
  }]);
});

test('log exists failure skips writing, and a failed job does not break the writer chain', async () => {
  const observer = freshObserver();
  const f = fixture();
  const exists = f.$.fs.exists;
  let fail = true;
  f.$.fs.exists = async path => { if (path === logPath && fail) throw new Error('exists failed'); return exists(path); };
  await spawn(observer, f, 'a1'); await step(observer, f, 'a1');
  assert.equal(f.writes.length, 0);
  fail = false;
  await spawn(observer, f, 'a2'); await step(observer, f, 'a2');
  assert.equal(f.records().length, 1);
  assert.equal(f.records()[0].agent_id, 'a2');
});

test('write failure and diagnostic failure do not break later writes', async () => {
  const observer = freshObserver();
  const f = fixture();
  const write = f.$.fs.write;
  let attempts = 0;
  f.$.fs.write = async (...args) => { if (++attempts === 1) throw new Error('write failed'); return write(...args); };
  f.$.ui.log = () => { throw new Error('debug failed'); };
  await spawn(observer, f, 'a1'); await step(observer, f, 'a1');
  await spawn(observer, f, 'a2'); await step(observer, f, 'a2');
  assert.equal(f.records().length, 1);
  assert.equal(f.records()[0].agent_id, 'a2');
});

test('overflow flushes oldest pending spawn with effort unobserved', async () => {
  const observer = freshObserver();
  observer.state.pending = new PendingSpawns(1);
  const f = fixture();
  await spawn(observer, f, 'a1'); await spawn(observer, f, 'a2');
  assert.equal(f.records()[0].agent_id, 'a1');
  assert.equal(f.records()[0].source, 'pending-overflow');
  assert.equal(f.records()[0].effort_observed, false);
  await step(observer, f, 'a1');
  assert.equal(observer.state.earlySteps.has('a1'), false);
  assert.equal(f.writes.length, 1);
  for (let i = 0; i < 257; i++) observer.state.recorded.add(`done-${i}`, true);
  assert.equal(observer.state.recorded.size, 256);
  assert.equal(observer.state.recorded.has('done-0'), false);
});

test('denied results are forwarded unchanged and their text is never recorded', async () => {
  const observer = freshObserver();
  const f = fixture();
  const answer = freeze({ deny: 'secret-denial' });
  assert.equal(await observer.hooks['agent.spawn'](f.$, freeze(eventInput('agent.spawn')), async () => answer), answer);
  assert.equal(f.records()[0].denied, true);
  assert.equal(f.records()[0].source, 'agent.spawn');
  assert.equal(f.writes[0].text.includes('secret-denial'), false);
});

test('a successful result carrying deny undefined is not marked denied', async () => {
  const observer = freshObserver();
  const f = fixture();
  await spawn(observer, f, 'a1', {}, { deny: undefined });
  await step(observer, f);
  assert.equal(f.records()[0].denied, false);
  assert.equal(f.records()[0].verdict, 'match');
});

test('profiles are read fresh, and unmanaged names never trigger profile reads', async () => {
  const observer = freshObserver();
  const f = fixture();
  await spawn(observer, f, 'a1'); await step(observer, f, 'a1');
  f.files.set(profilePath, profile.replace('opus[1m]', 'sonnet[1m]'));
  await spawn(observer, f, 'a2'); await step(observer, f, 'a2');
  assert.deepEqual(f.records().map(record => record.verdict), ['match', 'mismatch']);
  const profileReads = f.reads.filter(path => path === profilePath).length;
  await spawn(observer, f, 'a3', { subagentType: 'plugin:agent' }); await step(observer, f, 'a3');
  assert.equal(f.reads.filter(path => path === profilePath).length, profileReads);
  assert.equal(f.records()[2].profile, 'unmanaged-name');
});

test('missing, ENOENT and other profile failures have distinct statuses', async () => {
  for (const scenario of ['missing', 'ENOENT', 'EACCES']) {
    const observer = freshObserver();
    const f = fixture();
    if (scenario === 'missing') f.files.delete(profilePath);
    else f.$.fs.read = async () => { throw new Error(`${scenario}: /private/profile`); };
    await spawn(observer, f); await step(observer, f);
    assert.equal(f.records()[0].profile, scenario === 'EACCES' ? 'unreadable' : 'missing');
    assert.equal(f.writes[0].text.includes('/private/profile'), false);
  }
});
