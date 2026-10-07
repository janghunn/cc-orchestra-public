import { test, expect } from 'claude-code/testing';

for (const [name, model, agentId, verdict] of [
  ['registers and passes a spawn through', 'claude-opus-5-5', 'a1', 'match'],
  ['never denies', 'claude-sonnet-5-5', 'a2', 'mismatch'],
]) {
  test(name, async ($, on) => {
    const profilePath = '/home/fake/.claude/agents/lead-charlie.md';
    const writes: Array<{ path: string; text: string }> = [];
    on('env.get', async ($$, e, next) => ({ value: e.name === 'HOME' ? '/home/fake' : undefined }));
    on('fs.exists', async ($$, e, next) => ({ value: e.path === profilePath }));
    on('fs.read', async ($$, e, next) => ({
      value: e.path === profilePath ? '---\nname: lead-charlie\nmodel: opus[1m]\neffort: high\n---\n' : '',
    }));
    on('fs.write', async ($$, e, next) => {
      writes.push({ path: e.path, text: e.text });
      return { value: undefined };
    });
    on('session.id', async ($$, e, next) => ({ value: 's1' }));
    on('session.version', async ($$, e, next) => ({ value: { version: '2.1.292', base: '2.1.292' } }));
    on('ui.log', async ($$, e, next) => ({ value: undefined }));
    on('agent.spawn', async ($$, e, next) => ({ model, agentId }));
    on('turn.step', async function* ($$, e, next) {
      yield { kind: 'text', index: 0, text: 'private-answer' } as any;
      return { turnId: e.turnId, index: e.index, answer: 'private-answer', toolUses: [], stopReason: 'end_turn', usage: null } as any;
    });
    const result = await $.agent.spawn({ prompt: 'secret-prompt', subagentType: 'lead-charlie' });
    expect(result.model).toBe(model);
    expect(result.agentId).toBe(agentId);
    expect('deny' in result).toBe(false);
    const stream = $.turn.step({ turnId: 't1', index: 0, model, effort: 'high', messageCount: 1, agentId } as any);
    while (!(await stream.next()).done) { /* drain the model response */ }
    expect(writes.length).toBe(1);
    expect(writes[0].path).toBe('/home/fake/.claude/orchestra-state/spawn-observer.jsonl');
    const record = JSON.parse(writes[0].text.trim().split('\n').at(-1)!);
    expect(record.verdict).toBe(verdict);
    expect(writes[0].text.includes('secret-prompt')).toBe(false);
    expect(writes[0].text.includes('private-answer')).toBe(false);
  });
}
