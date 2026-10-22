import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createLocalServer } from '../server.mjs';
import { createFileStore } from '../lib/sync.mjs';
import { emptyState, enqueue, prepareChanges, applyResponse, resolveConflict } from '../public/queue.mjs';

test('mobile queue round-trips over the real HTTP API while other screens edit', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'noty-mobile-http-'));
  const key = 'noty-mobile-test-private-key-32-characters';
  const server = createLocalServer({ token: key, store: createFileStore(join(directory, 'tasks.json')) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true }); });
  const url = `http://127.0.0.1:${server.address().port}/api/sync`;
  async function post(changes) {
    const response = await fetch(url, {
      method: 'POST', headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ changes: changes.map(({ task, base }) => ({ task, base })) }),
    });
    assert.equal(response.status, 200);
    return response.json();
  }
  const state = emptyState();
  const initial = {
    id: '697A75E1-48E4-444F-A029-F302BD31E2AB', noteId: '8A1BE443-03C4-4934-8D5B-EA6E8BB1F8C1',
    listTitle: 'Today', text: 'Buy tea', completed: false, position: 0, deleted: false, version: 0,
  };
  enqueue(state, initial);
  const creation = prepareChanges(state);
  applyResponse(state, await post(creation), creation);
  const base = state.tasks[initial.id];
  assert.equal(base.version, 1);
  enqueue(state, { ...base, text: 'Buy coffee' });
  const sent = prepareChanges(state);
  await post([{ task: { ...base, completed: true }, base }]);
  const accepted = await post(sent);
  // The user types another edit before the first response reaches the queue.
  enqueue(state, { ...state.pending[base.id].task, text: 'Buy coffee beans' });
  applyResponse(state, accepted, sent);
  assert.equal(state.pending[base.id].task.completed, true);
  assert.equal(state.pending[base.id].task.text, 'Buy coffee beans');
  assert.equal(state.pending[base.id].base.version, 3);
  const subsequent = prepareChanges(state);
  applyResponse(state, await post(subsequent), subsequent);
  assert.equal(Object.keys(state.pending).length, 0);

  const conflictBase = state.tasks[base.id];
  enqueue(state, { ...conflictBase, text: 'Phone edit' });
  const conflicting = prepareChanges(state);
  await post([{ task: { ...conflictBase, text: 'Laptop edit' }, base: conflictBase }]);
  applyResponse(state, await post(conflicting), conflicting);
  assert.equal(prepareChanges(state).length, 0);
  assert.equal(state.conflicts[base.id].task.text, 'Laptop edit');
  resolveConflict(state, base.id, 'local');
  const resolution = prepareChanges(state);
  applyResponse(state, await post(resolution), resolution);
  assert.equal(state.tasks[base.id].text, 'Phone edit');
  assert.equal(Object.keys(state.conflicts).length, 0);
  assert.equal(Object.keys(state.pending).length, 0);
});
