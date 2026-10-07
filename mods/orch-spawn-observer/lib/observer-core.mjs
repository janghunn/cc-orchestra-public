// Pure data handling; also runs in the mods sandbox (no Node or DOM APIs).
export const OBSERVER_VERSION = '0.1.0';
export const MIN_HOST_VERSION = '2.1.287';
export const PENDING_CAP = 64;
export const LOG_MAX_BYTES = 1048576;
export const LOG_KEEP_BYTES = 524288;

export function isManagedTypeName(name) {
  return typeof name === 'string' && name === name.trim() && /^[A-Za-z0-9_-]{1,64}$/.test(name);
}

function joinPath(dir, suffix) {
  return `${dir.replace(/\/+$/, '')}/${suffix}`;
}

export function profilePath(config, agentType) {
  return config && isManagedTypeName(agentType) ? joinPath(config, `agents/${agentType}.md`) : null;
}

export function parseProfile(text) {
  if (typeof text !== 'string') return { status: 'malformed', reason: 'profile is not text' };
  const lines = text.replace(/^\uFEFF/, '').split(/\r?\n/);
  if (lines[0] !== '---') return { status: 'malformed', reason: 'no opening ---' };
  const end = lines.indexOf('---', 1);
  if (end < 0) return { status: 'malformed', reason: 'no closing ---' };
  const values = { model: null, effort: null };
  const seen = new Set();
  for (const line of lines.slice(1, end)) {
    const match = /^(model|effort):\s*(.*)$/.exec(line);
    if (!match || seen.has(match[1])) continue;
    seen.add(match[1]);
    let value = match[2].trim();
    if (value.length >= 2 && ((value[0] === '"' && value.at(-1) === '"') ||
        (value[0] === "'" && value.at(-1) === "'"))) value = value.slice(1, -1);
    values[match[1]] = value || null;
  }
  return { status: 'ok', ...values };
}

export function normalizeModel(id) {
  return typeof id === 'string' ? id.trim().toLowerCase().replace(/\[[^\[\]]*\]$/, '').trim() : null;
}

export function modelFamily(id) {
  const model = typeof id === 'string' ? id.toLowerCase() : null;
  return ['fable', 'opus', 'sonnet', 'haiku'].find(family => model?.includes(family)) ?? null;
}

export function modelsEquivalent(expected, actual) {
  const left = normalizeModel(expected);
  const right = normalizeModel(actual);
  if (!left || !right) return null;
  const leftFamily = modelFamily(expected);
  const rightFamily = modelFamily(actual);
  return leftFamily && rightFamily ? leftFamily === rightFamily : left === right;
}

export function normalizeEffort(value) {
  if (typeof value !== 'string' && typeof value !== 'number') return null;
  return String(value).trim().toLowerCase() || null;
}

export function expectationFromProfile({ agentType, lookup, parentModel }) {
  const empty = { expected_model: null, expected_effort: null };
  if (!isManagedTypeName(agentType) || lookup.kind === 'unmanaged-name') {
    return { profile: 'unmanaged-name', ...empty };
  }
  if (lookup.kind !== 'text') {
    return { profile: lookup.kind, ...empty, ...(lookup.reason ? { reason: lookup.reason } : {}) };
  }
  const parsed = parseProfile(lookup.text);
  if (parsed.status === 'malformed') return { profile: 'malformed', ...empty, reason: parsed.reason };
  const inherit = normalizeModel(parsed.model) === 'inherit';
  return {
    profile: 'found',
    expected_model: inherit ? parentModel ?? null : parsed.model,
    expected_effort: parsed.effort,
    ...(inherit ? { model_inherit: true } : {}),
  };
}

export function compare({ expectation, effectiveModel, effectiveEffort, effortObserved }) {
  const { profile, expected_model: model, expected_effort: effort } = expectation;
  if (profile === 'unmanaged-name' || profile === 'missing') return { verdict: 'unmanaged', reasons: [] };
  if (profile === 'found' && !model && !effort) {
    return { verdict: 'unmanaged', reasons: ['profile pins nothing'] };
  }
  if (profile === 'malformed' || profile === 'unreadable') {
    return { verdict: 'unknown', reasons: [`profile ${profile}`] };
  }
  const reasons = [];
  let mismatch = false;
  let unknown = false;
  if (model) {
    const equivalent = modelsEquivalent(model, effectiveModel);
    if (equivalent === false) {
      mismatch = true;
      reasons.push(`model: expected ${model} got ${effectiveModel}`);
    } else if (equivalent === null) {
      unknown = true;
      reasons.push('model not observed');
    }
  }
  if (effort) {
    const observed = normalizeEffort(effectiveEffort);
    if (!effortObserved || observed === null) {
      unknown = true;
      reasons.push('effort not observed');
    } else if (normalizeEffort(effort) !== observed) {
      mismatch = true;
      reasons.push(`effort: expected ${effort} got ${effectiveEffort}`);
    }
  }
  return { verdict: mismatch ? 'mismatch' : unknown ? 'unknown' : 'match', reasons };
}

const stringOrNull = value => typeof value === 'string' ? value.slice(0, 200) : null;

export function buildRecord(fields) {
  const observed = Boolean(fields.effortObserved);
  const stepModel = observed ? fields.stepModel ?? null : null;
  const answeredModel = observed ? fields.answeredModel ?? null : null;
  const effectiveModel = answeredModel ?? stepModel ?? fields.spawnModel ?? null;
  const stepEffort = observed
    ? (typeof fields.stepEffort === 'number' ? String(fields.stepEffort) : fields.stepEffort ?? null) : null;
  const comparison = compare({
    expectation: fields.expectation, effectiveModel, effectiveEffort: stepEffort, effortObserved: observed,
  });
  // Explicit allowlist: no event/result spreading, prompt, output, paths, or deny text.
  return {
    ts: stringOrNull(fields.ts ?? new Date().toISOString()),
    observer: `orch-spawn-observer@${OBSERVER_VERSION}`,
    host_version: stringOrNull(fields.hostVersion),
    session_id: stringOrNull(fields.sessionId),
    agent_id: stringOrNull(fields.agentId),
    agent_type: stringOrNull(fields.agentType) ?? '',
    fork: Boolean(fields.fork),
    teammate: typeof fields.teammate === 'boolean' ? fields.teammate : null,
    parent_model: stringOrNull(fields.parentModel),
    requested_model: stringOrNull(fields.requestedModel),
    requested_effort: null,
    effective_model: stringOrNull(effectiveModel),
    step_model: stringOrNull(stepModel),
    answered_model: stringOrNull(answeredModel),
    step_effort: stringOrNull(stepEffort),
    effort_source: observed ? 'turn.step-input' : null,
    effort_observed: observed,
    expected_model: stringOrNull(fields.expectation.expected_model),
    expected_effort: stringOrNull(fields.expectation.expected_effort),
    profile: stringOrNull(fields.expectation.profile),
    verdict: comparison.verdict,
    reasons: comparison.reasons.map(stringOrNull),
    source: stringOrNull(fields.source),
    denied: Boolean(fields.denied),
  };
}

function utf8Bytes(text) {
  let bytes = 0;
  for (const character of text) {
    const code = character.codePointAt(0);
    bytes += code <= 0x7f ? 1 : code <= 0x7ff ? 2 : code <= 0xffff ? 3 : 4;
  }
  return bytes;
}

export function appendJsonl(existingText, records, { maxBytes = LOG_MAX_BYTES, keepBytes = LOG_KEEP_BYTES } = {}) {
  const prefix = existingText && !existingText.endsWith('\n') ? `${existingText}\n` : existingText;
  const text = prefix + records.map(record => `${JSON.stringify(record)}\n`).join('');
  let bytes = utf8Bytes(text);
  if (bytes <= maxBytes) return text;
  const lines = text.split('\n');
  let first = 0;
  while (bytes > keepBytes && first < lines.length - 1) {
    bytes -= utf8Bytes(lines[first++]) + 1;
  }
  return lines.slice(first).join('\n');
}

export class PendingSpawns {
  constructor(cap = PENDING_CAP) {
    this.cap = cap;
    this.entries = new Map();
  }
  add(agentId, entry) {
    this.entries.set(agentId, entry);
    const evicted = [];
    while (this.entries.size > this.cap) {
      const oldest = this.entries.keys().next().value;
      evicted.push(this.take(oldest));
    }
    return evicted;
  }
  take(agentId) {
    const entry = this.entries.get(agentId);
    this.entries.delete(agentId);
    return entry;
  }
  drain() {
    const entries = [...this.entries.values()];
    this.entries.clear();
    return entries;
  }
  get size() { return this.entries.size; }
  has(agentId) { return this.entries.has(agentId); }
}

export class EarlySteps extends PendingSpawns {}

export function versionAtLeast(version, min) {
  const parse = value => typeof value === 'string' ? /^(\d+)\.(\d+)\.(\d+)(?=$|[^\d])/.exec(value) : null;
  const left = parse(version);
  const right = parse(min);
  if (!left || !right) return null;
  for (let i = 1; i <= 3; i++) {
    if (Number(left[i]) !== Number(right[i])) return Number(left[i]) > Number(right[i]);
  }
  return true;
}

export function stateLogPath(env) {
  const dir = env.CC_ORCH_STATE_DIR || (env.HOME ? joinPath(env.HOME, '.claude/orchestra-state') : null);
  return dir ? joinPath(dir, 'spawn-observer.jsonl') : null;
}

export function configDir(env) {
  return env.CLAUDE_CONFIG_DIR || (env.HOME ? joinPath(env.HOME, '.claude') : null);
}
