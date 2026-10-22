import test from 'node:test';
import assert from 'node:assert/strict';
import { emptyState, restoreState, enqueue, prepareChanges, applyResponse, resolveConflict, visibleTasks } from '../public/queue.mjs';

const task = (overrides = {}) => ({
  id: 'F93C31AD-D613-432E-B125-313CF3B98159',
  noteId: 'B669CFE4-0112-4D08-9ACB-A0B152B8C8A2',
  listTitle: 'Today', text: 'Buy tea', completed: false,
  position: 1, deleted: false, version: 1, ...overrides,
});
const response = (tasks, conflicts = []) => ({ tasks, conflicts });
const initial = () => applyResponse(emptyState(), response([task()]));

test('offline edits survive reload and retain the original server base', () => {
  let state = initial();
  enqueue(state, task({ text: 'Buy coffee' }));
  state = restoreState(JSON.parse(JSON.stringify(state)));
  enqueue(state, task({ text: 'Buy coffee and tea', completed: true }));
  const [change] = prepareChanges(state);
  assert.equal(change.base.text, 'Buy tea');
  assert.equal(change.base.completed, false);
  assert.equal(change.task.text, 'Buy coffee and tea');
  assert.equal(change.task.completed, true);
});

test('polling remote changes does not replace an unsent edit or its base', () => {
  const state = initial();
  enqueue(state, task({ text: 'Buy coffee' }));
  applyResponse(state, response([task({ completed: true, version: 2 })]));
  assert.equal(visibleTasks(state)[0].text, 'Buy coffee');
  assert.equal(prepareChanges(state)[0].base.version, 1);
});

test('acknowledgement preserves edits made in flight and adopts merged remote fields', () => {
  const state = initial();
  enqueue(state, task({ text: 'Buy coffee' }));
  const sent = prepareChanges(state);
  enqueue(state, task({ text: 'Buy coffee', completed: true }));
  const accepted = task({ text: 'Buy coffee', listTitle: 'Groceries', version: 2 });
  applyResponse(state, response([accepted]), sent);
  const [next] = prepareChanges(state);
  assert.deepEqual(next.base, accepted);
  assert.equal(next.task.completed, true);
  assert.equal(next.task.listTitle, 'Groceries');
  assert.equal(next.task.version, 2);
  applyResponse(state, response([task({ ...next.task, version: 3 })]), prepareChanges(state));
  assert.equal(prepareChanges(state).length, 0);
});

test('an edit undone during a request sends the reversal against the accepted edit', () => {
  const state = initial();
  enqueue(state, task({ text: 'Buy coffee' }));
  const sent = prepareChanges(state);
  enqueue(state, task());
  applyResponse(state, response([task({ text: 'Buy coffee', version: 2 })]), sent);
  assert.equal(prepareChanges(state)[0].task.text, 'Buy tea');
  assert.equal(prepareChanges(state)[0].base.text, 'Buy coffee');
});

test('conflicts stay blocked across polls and keep-edit rebases explicitly', () => {
  const state = initial();
  enqueue(state, task({ text: 'Buy coffee' }));
  const remote = task({ text: 'Buy milk', version: 2 });
  applyResponse(state, response([remote], [{ id: remote.id, task: remote }]), prepareChanges(state));
  assert.equal(prepareChanges(state).length, 0);
  assert.equal(visibleTasks(state)[0].text, 'Buy coffee');
  const newer = task({ text: 'Buy oat milk', version: 3 });
  applyResponse(state, response([newer]));
  assert.equal(state.conflicts[remote.id].task.text, 'Buy oat milk');
  resolveConflict(state, remote.id, 'local');
  assert.deepEqual(prepareChanges(state)[0].base, newer);
  assert.equal(prepareChanges(state)[0].task.text, 'Buy coffee');
});

test('taking server conflict discards only that local edit', () => {
  const state = initial();
  enqueue(state, task({ text: 'Buy coffee' }));
  const deleted = task({ deleted: true, version: 2 });
  applyResponse(state, response([deleted], [{ id: deleted.id, task: deleted }]), prepareChanges(state));
  resolveConflict(state, deleted.id, 'server');
  assert.equal(prepareChanges(state).length, 0);
  assert.equal(visibleTasks(state).length, 0);
});

test('keeping a remotely deleted task recovers the edit under a new ID', () => {
  const state = initial();
  enqueue(state, task({ text: 'Buy coffee' }));
  const deleted = task({ deleted: true, version: 2 });
  applyResponse(state, response([deleted], [{ id: deleted.id, task: deleted }]), prepareChanges(state));
  const newId = '6c7df8d9-c9cc-4d60-af07-8e5cbda42c01';
  resolveConflict(state, deleted.id, 'local', newId);
  const [change] = prepareChanges(state);
  assert.equal(change.task.id, newId);
  assert.equal(change.task.text, 'Buy coffee');
  assert.equal(change.task.deleted, false);
  assert.equal(change.task.version, 0);
  assert.equal(change.base, null);
  assert.equal(state.tasks[deleted.id].deleted, true);
  assert.equal(visibleTasks(state).length, 1);
});

test('keeping a conflict preserves independent remote completion changes', () => {
  const state = initial();
  enqueue(state, task({ text: 'Buy coffee' }));
  const remote = task({ text: 'Buy milk', completed: true, version: 2 });
  applyResponse(state, response([remote], [{ id: remote.id, task: remote }]), prepareChanges(state));
  resolveConflict(state, remote.id, 'local');
  assert.equal(prepareChanges(state)[0].task.text, 'Buy coffee');
  assert.equal(prepareChanges(state)[0].task.completed, true);
});

test('new tasks retain a null base through edits and offline deletion', () => {
  const state = emptyState();
  enqueue(state, task({ version: 0 }));
  enqueue(state, task({ version: 0, text: 'Coffee beans' }));
  enqueue(state, task({ version: 0, text: 'Coffee beans', deleted: true }));
  assert.equal(prepareChanges(state)[0].base, null);
  assert.equal(prepareChanges(state)[0].task.deleted, true);
  assert.equal(visibleTasks(state).length, 0);
});

test('malformed responses cannot acknowledge or erase a queued edit', () => {
  const state = initial();
  enqueue(state, task({ text: 'Buy coffee' }));
  assert.throws(() => applyResponse(state, response([{ ...task(), version: '2' }]), prepareChanges(state)));
  assert.equal(prepareChanges(state)[0].task.text, 'Buy coffee');
});

test('a partial acknowledgement retains the missing task for retry', () => {
  const state = initial();
  enqueue(state, task({ text: 'Buy coffee' }));
  applyResponse(state, response([]), prepareChanges(state));
  assert.equal(prepareChanges(state)[0].base.text, 'Buy tea');
});
