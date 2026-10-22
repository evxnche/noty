import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createLocalServer } from '../server.mjs';
import { createFileStore } from '../lib/sync.mjs';
import { emptyNoteState, restoreNoteState, enqueueNote, prepareNoteChanges, applyNoteResponse, resolveNoteConflict } from '../public/notes-queue.mjs';

test('mobile note queue preserves offline fulltext, board edits and explicit conflicts over HTTP', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'noty-note-mobile-'));
  const token = 'noty-notes-mobile-HTTP-key-at-least-32-characters';
  const server = createLocalServer({ token, store: createFileStore(join(directory, 'snapshot.json')) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true }); });
  async function request(route, changes) {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/api/${route}`, {
      method: changes ? 'POST' : 'GET', headers: { Authorization: `Bearer ${token}`, ...(changes ? { 'Content-Type': 'application/json' } : {}) },
      ...(changes ? { body: JSON.stringify({ changes }) } : {}),
    });
    assert.equal(response.status, 200);
    return response.json();
  }
  const post = sent => request('notes', sent.map(({ note, base }) => ({ note, base })));
  let state = emptyNoteState();
  const note = { id: 'B0000000-0000-4000-8000-000000000001', title: 'Work', body: 'Original context\n- [ ] Tea\n# idea\nLamp', archived: false, deleted: false, version: 0, taskIds: [] };
  enqueueNote(state, note);
  let sent = prepareNoteChanges(state);
  applyNoteResponse(state, await post(sent), sent);
  const base = state.notes[note.id];
  assert.equal(base.version, 1);
  assert.equal(base.taskIds.length, 1);
  enqueueNote(state, { ...base, body: base.body.replace('Lamp', 'Phone lamp 🧑🏽‍💻') });
  state = restoreNoteState(JSON.parse(JSON.stringify(state)));
  const boardTask = (await request('sync')).tasks[0];
  await request('sync', [{ task: { ...boardTask, completed: true }, base: boardTask }]);
  sent = prepareNoteChanges(state);
  applyNoteResponse(state, await post(sent), sent);
  assert.equal(state.notes[note.id].body, base.body.replace('[ ]', '[x]').replace('Lamp', 'Phone lamp 🧑🏽‍💻'));
  assert.equal(Object.keys(state.pending).length, 0);

  const conflictBase = state.notes[note.id];
  enqueueNote(state, { ...conflictBase, body: 'Offline phone text 📱' });
  sent = prepareNoteChanges(state);
  await request('notes', [{ note: { ...conflictBase, body: 'Mac text 💻' }, base: conflictBase }]);
  applyNoteResponse(state, await post(sent), sent);
  assert.equal(state.pending[note.id].note.body, 'Offline phone text 📱');
  assert.equal(state.conflicts[note.id].note.body, 'Mac text 💻');
  resolveNoteConflict(state, note.id, 'local');
  sent = prepareNoteChanges(state);
  applyNoteResponse(state, await post(sent), sent);
  assert.equal(state.notes[note.id].body, 'Offline phone text 📱');
  assert.equal(Object.keys(state.pending).length, 0);
});
