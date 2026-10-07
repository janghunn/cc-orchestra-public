import * as observerCore from '../lib/observer-core.mjs';

let core = observerCore;
let state = newState();

function newState() {
  return {
    disabled: false,
    disabledReason: null,
    disabledLogged: false,
    observeSteps: true,
    hostVersion: null,
    versionRead: false,
    writeFailedLogged: false,
    pending: new observerCore.PendingSpawns(),
    earlySteps: new observerCore.EarlySteps(),
    recorded: new observerCore.EarlySteps(256),
    writer: Promise.resolve(),
  };
}

export const __testing = {
  reset() { core = observerCore; state = newState(); },
  setCore(overrides) { core = { ...observerCore, ...overrides }; },
  get state() { return state; },
};

async function debug(io, message) {
  try { await io.log(message); } catch { /* diagnostics are optional */ }
}

const unreadable = () => ({ profile: 'unreadable', expected_model: null, expected_effort: null });

async function lookup(io, e) {
  try {
    let found;
    if (!core.isManagedTypeName(e.subagentType)) {
      found = { kind: 'unmanaged-name' };
    } else {
      const config = core.configDir(await io.configEnv());
      const path = core.profilePath(config, e.subagentType);
      if (!path) found = { kind: 'unreadable' };
      else {
        try {
          found = await io.exists(path) === false
            ? { kind: 'missing' } : { kind: 'text', text: await io.read(path) };
        } catch (error) {
          // Do not put filesystem errors (which may include private paths) in records.
          found = { kind: String(error?.message ?? error).includes('ENOENT') ? 'missing' : 'unreadable' };
        }
      }
    }
    return core.expectationFromProfile({ agentType: e.subagentType, lookup: found, parentModel: e.parentModel });
  } catch { return unreadable(); }
}

function enqueue(io, records) {
  if (!records.length) return state.writer;
  state.writer = state.writer.then(async () => {
    const path = core.stateLogPath(await io.logEnv());
    if (!path) return;
    // A failed read must never turn into an empty file and erase earlier records.
    const exists = await io.exists(path);
    const previous = exists === false ? '' : await io.read(path);
    await io.write(path, core.appendJsonl(previous, records));
  }).catch(async error => {
    try {
      if (!state.writeFailedLogged) {
        state.writeFailedLogged = true;
        await debug(io, `orch-spawn-observer: log write failed: ${String(error?.message ?? error).slice(0, 200)}`);
      }
    } catch { /* even formatting a diagnostic must not reject the writer chain */ }
  });
  return state.writer;
}

function markRecorded(entry) {
  if (entry.agentId) state.recorded.add(entry.agentId, true);
}

async function record(io, entry, step, source) {
  const answeredModel = step ? await step.answeredModelP : null;
  const expectation = await entry.expectationP;
  let sessionId = null;
  try { sessionId = await io.sessionId(); } catch { /* id is optional */ }
  return core.buildRecord({
    ...entry, expectation, sessionId, hostVersion: state.hostVersion,
    stepModel: step?.stepModel, stepEffort: step?.stepEffort,
    answeredModel, effortObserved: Boolean(step), source,
  });
}

async function flush(io, entries, source) {
  for (const entry of entries) markRecorded(entry);
  const records = await Promise.all(entries.map(entry => record(io, entry, null, source)));
  await enqueue(io, records);
}

export async function agentSpawn($, e, next) {
  let io;
  let expectationP;
  try {
    if (!state.disabled) {
      // API closures must be created in the hook for the engine's static analysis.
      io = {
        exists: path => $.fs.exists(path),
        read: path => $.fs.read(path),
        write: (path, text) => $.fs.write(path, text),
        log: message => $.ui.log(message, { to: 'debug' }),
        sessionId: () => $.session.id(),
        configEnv: async () => ({
          CLAUDE_CONFIG_DIR: await $.env.get('CLAUDE_CONFIG_DIR'),
          HOME: await $.env.get('HOME'),
        }),
        logEnv: async () => ({
          CC_ORCH_STATE_DIR: await $.env.get('CC_ORCH_STATE_DIR'),
          HOME: await $.env.get('HOME'),
        }),
      };
      // Start I/O without delaying next: the first step can precede the spawn result.
      expectationP = lookup(io, e);
    }
  } catch { /* observe only */ }
  const result = await next(e);
  if (!state.disabled) {
    try {
      const agentId = typeof result?.agentId === 'string' && result.agentId ? result.agentId : null;
      const entry = {
        ts: new Date().toISOString(), expectationP: expectationP ?? Promise.resolve(unreadable()),
        agentId, agentType: e.subagentType, fork: e.fork, teammate: e.isTeammate,
        parentModel: e.parentModel, requestedModel: e.model,
        spawnModel: result?.model, denied: typeof result?.deny === 'string',
      };
      if (agentId && state.observeSteps) {
        // No await between taking an early step and installing its bookkeeping.
        const early = state.earlySteps.take(agentId);
        if (early) {
          markRecorded(entry);
          if (early.done) {
            await enqueue(io, [await record(io, entry, early, 'agent.spawn+turn.step')]);
          } else {
            // The step hook owns completion; never hold the spawn open for its stream.
            early.entry = entry;
          }
        } else {
          const evicted = state.pending.add(agentId, entry);
          if (evicted.length) await flush(io, evicted, 'pending-overflow');
        }
      } else {
        await flush(io, [entry], 'agent.spawn');
      }
    } catch { /* observer failures must not replace the engine result */ }
  }
  return result;
}

export async function* turnStep($, e, next) {
  let entry;
  let step;
  let resolveAnswered;
  if (!state.disabled && state.observeSteps) {
    try {
      const id = e.agentId;
      if (typeof id === 'string' && id) {
        entry = state.pending.take(id);
        if (entry || (!state.recorded.has(id) && !state.earlySteps.has(id))) {
          step = {
            stepModel: e.model, stepEffort: e.effort, done: false, entry: null,
            answeredModelP: new Promise(resolve => { resolveAnswered = resolve; }),
          };
          if (entry) markRecorded(entry);
          else state.earlySteps.add(id, step);
        }
      }
    } catch { /* main and unrelated loops never perform I/O */ }
  }
  let result;
  try {
    result = yield* next(e);
  } finally {
    try {
      if (step) {
        step.done = true;
        resolveAnswered(result?.usage?.model ?? null);
        const completedEntry = entry ?? step.entry;
        if (completedEntry) {
          const io = {
            exists: path => $.fs.exists(path),
            read: path => $.fs.read(path),
            write: (path, text) => $.fs.write(path, text),
            log: message => $.ui.log(message, { to: 'debug' }),
            sessionId: () => $.session.id(),
            logEnv: async () => ({
              CC_ORCH_STATE_DIR: await $.env.get('CC_ORCH_STATE_DIR'),
              HOME: await $.env.get('HOME'),
            }),
          };
          await enqueue(io, [await record(io, completedEntry, step, 'agent.spawn+turn.step')]);
        }
      }
    } catch { /* preserve stream failures, chunks and the exact return value */ }
  }
  return result;
}

export async function sessionStart($, e, next) {
  const result = await next(e);
  try {
    if (!state.disabled && !state.versionRead) {
      state.versionRead = true;
      const host = await $.session.version();
      state.hostVersion = typeof host?.version === 'string' ? host.version : null;
      if (core.versionAtLeast(host?.base ?? state.hostVersion, core.MIN_HOST_VERSION) === false) {
        state.disabled = true;
        state.disabledReason = `orch-spawn-observer: host older than ${core.MIN_HOST_VERSION}; observer disabled`;
      }
    }
    if (state.disabled && !state.disabledLogged) {
      state.disabledLogged = true;
      const io = { log: message => $.ui.log(message, { to: 'debug' }) };
      await debug(io, state.disabledReason);
    }
  } catch { /* host metadata is optional */ }
  return result;
}

export async function sessionEnd($, e, next) {
  const result = await next(e);
  if (!state.disabled) {
    try {
      const io = {
        exists: path => $.fs.exists(path),
        read: path => $.fs.read(path),
        write: (path, text) => $.fs.write(path, text),
        log: message => $.ui.log(message, { to: 'debug' }),
        sessionId: () => $.session.id(),
        logEnv: async () => ({
          CC_ORCH_STATE_DIR: await $.env.get('CC_ORCH_STATE_DIR'),
          HOME: await $.env.get('HOME'),
        }),
      };
      await flush(io, state.pending.drain(), 'session.end');
      state.earlySteps.drain();
    } catch { /* observation must not prevent session shutdown */ }
  }
  return result;
}

const passThrough = ($, e, next) => next(e);

export function register(on, options) {
  try {
    on('agent.spawn', agentSpawn).catch(passThrough);
  } catch {
    state.disabled = true;
    state.disabledReason = 'orch-spawn-observer: agent.spawn not offered by this host; observer disabled';
  }
  try { on('turn.step', turnStep); } catch { state.observeSteps = false; }
  try { on('session.start', sessionStart).catch(passThrough); } catch { /* unavailable */ }
  try { on('session.end', sessionEnd).catch(passThrough); } catch { /* unavailable */ }
}
