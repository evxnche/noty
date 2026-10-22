import test from 'node:test';
import assert from 'node:assert/strict';

const api = await import('../public/notes-queue.mjs').catch(() => ({}));
const note = (extra = {}) => ({ id: 'B0000000-0000-4000-8000-000000000001', title: 'Desk Pal', body: '# to-do\nMilk\n# idea\nLamp', archived: false, deleted: false, version: 1, taskIds: ['A0000000-0000-4000-8000-000000000001'], ...extra });
function backend() { assert.equal(typeof api.emptyNoteState, 'function', 'full-note queue must exist'); return api; }

test('full-note offline drafts keep original base through edits and reload', () => {
  const q = backend();
  const state = q.emptyNoteState();
  q.applyNoteResponse(state, { notes: [note()], conflicts: [], deskPalId: note().id });
  q.enqueueNote(state, note({ body: note().body + '\n🧑🏽‍💻 café' }));
  q.enqueueNote(state, { ...state.pending[note().id].note, title: 'Desk Pal 📔' });
  const restored = q.restoreNoteState(JSON.parse(JSON.stringify(state)));
  assert.deepEqual(restored.pending[note().id].base, note());
  assert.equal(restored.pending[note().id].note.title, 'Desk Pal 📔');
  assert.ok(restored.pending[note().id].note.body.includes('🧑🏽‍💻 café'));
  assert.equal(restored.deskPalId, note().id);
});

test('in-flight full-note edits rebase on acknowledged fields and canonical IDs', () => {
  const q = backend();
  const state = q.emptyNoteState();
  q.applyNoteResponse(state, { notes: [note()], conflicts: [], deskPalId: note().id });
  q.enqueueNote(state, note({ body: note().body.replace('Milk', 'Tea') }));
  const sent = q.prepareNoteChanges(state);
  q.enqueueNote(state, { ...state.pending[note().id].note, body: note().body.replace('Milk', 'Tea bags') });
  const accepted = note({ version: 3, title: 'Remote title', body: sent[0].note.body, taskIds: ['A0000000-0000-4000-8000-000000000002'] });
  q.applyNoteResponse(state, { notes: [accepted], conflicts: [], deskPalId: note().id }, sent);
  const pending = state.pending[note().id];
  assert.equal(pending.note.title, 'Remote title');
  assert.equal(pending.note.body, note().body.replace('Milk', 'Tea bags'));
  assert.deepEqual(pending.note.taskIds, accepted.taskIds);
  assert.deepEqual(pending.base, accepted);
});

test('conflicts keep both full texts and explicit choices resolve or recover tombstones', () => {
  const q = backend();
  const state = q.emptyNoteState();
  q.applyNoteResponse(state, { notes: [note()], conflicts: [], deskPalId: note().id });
  q.enqueueNote(state, note({ body: 'Phone text 🧑🏽‍💻' }));
  const sent = q.prepareNoteChanges(state);
  const remote = note({ body: 'Mac text 💻', version: 2 });
  q.applyNoteResponse(state, { notes: [remote], conflicts: [{ id: note().id, note: remote }], deskPalId: note().id }, sent);
  assert.equal(q.prepareNoteChanges(state).length, 0);
  assert.equal(state.pending[note().id].note.body, 'Phone text 🧑🏽‍💻');
  const restored = q.restoreNoteState(JSON.parse(JSON.stringify(state)));
  assert.equal(restored.conflicts[note().id].note.body, 'Mac text 💻');
  q.resolveNoteConflict(restored, note().id, 'local');
  assert.equal(restored.pending[note().id].note.body, 'Phone text 🧑🏽‍💻');
  assert.deepEqual(restored.pending[note().id].base, remote);
  q.resolveNoteConflict(state, note().id, 'server');
  assert.equal(Object.keys(state.pending).length, 0);
  assert.equal(q.visibleNotes(state)[0].body, 'Mac text 💻');
});

test('retry snapshots are independent and GET never acknowledges unsent text', () => {
  const q = backend();
  const state = q.emptyNoteState();
  q.applyNoteResponse(state, { notes: [note()], conflicts: [], deskPalId: note().id });
  q.enqueueNote(state, note({ body: 'Offline body' }));
  const sent = q.prepareNoteChanges(state);
  sent[0].note.taskIds.push('A0000000-0000-4000-8000-000000000002');
  assert.equal(state.pending[note().id].note.taskIds.length, 1);
  q.applyNoteResponse(state, { notes: [note({ title: 'Remote', version: 2 })], conflicts: [], deskPalId: note().id });
  assert.deepEqual(state.pending[note().id].base, note());
  assert.equal(q.visibleNotes(state)[0].body, 'Offline body');
});

test('edits typed in flight keep independent remote body lines and flag overlapping lines', () => {
  const q = backend();
  const state = q.emptyNoteState();
  q.applyNoteResponse(state, { notes: [note()], conflicts: [], deskPalId: note().id });
  q.enqueueNote(state, note({ body: note().body.replace('Milk', 'Tea') }));
  const sent = q.prepareNoteChanges(state);
  q.enqueueNote(state, { ...state.pending[note().id].note, body: note().body.replace('Milk', 'Tea bags') });
  const accepted = note({ version: 3, body: sent[0].note.body.replace('Lamp', 'Remote lamp') });
  q.applyNoteResponse(state, { notes: [accepted], conflicts: [], deskPalId: note().id }, sent);
  assert.equal(state.pending[note().id].note.body, accepted.body.replace('Tea', 'Tea bags'));

  const next = q.prepareNoteChanges(state);
  q.enqueueNote(state, { ...state.pending[note().id].note, body: 'New overlapping phone text' });
  const concurrent = { ...accepted, version: 4, body: 'New overlapping remote text' };
  q.applyNoteResponse(state, { notes: [concurrent], conflicts: [], deskPalId: note().id }, next);
  assert.equal(state.pending[note().id].note.body, 'New overlapping phone text');
  assert.equal(state.conflicts[note().id].note.body, 'New overlapping remote text');
});

test('the editor keeps its observed base if a poll lands between focus and typing', () => {
  const q = backend();
  const state = q.emptyNoteState();
  q.applyNoteResponse(state, { notes: [note()], conflicts: [], deskPalId: note().id });
  const observed = note();
  q.applyNoteResponse(state, { notes: [note({ body: 'Remote body', version: 2 })], conflicts: [], deskPalId: note().id });
  q.enqueueNote(state, note({ body: 'Phone body' }), observed);
  assert.deepEqual(state.pending[note().id].base, observed);
});

test('own acknowledgements advance a focused editor base and preserve caret for the next edit', () => {
  const q = backend();
  assert.equal(typeof q.editorAfterAcknowledgement, 'function');
  const state = q.emptyNoteState();
  q.applyNoteResponse(state, { notes: [note()], conflicts: [], deskPalId: note().id });
  q.enqueueNote(state, note({ body: note().body.replace('Milk', 'Tea') }));
  const sent = q.prepareNoteChanges(state);
  const accepted = note({ version: 3, body: sent[0].note.body.replace('Lamp', 'Remote lamp') });
  q.applyNoteResponse(state, { notes: [accepted], conflicts: [], deskPalId: note().id }, sent);
  const cursor = sent[0].note.body.indexOf('Tea') + 3;
  const editor = q.editorAfterAcknowledgement(state, sent, { id: note().id, field: 'body', value: sent[0].note.body, start: cursor, end: cursor });
  assert.deepEqual(editor.base, accepted);
  assert.equal(editor.note.body, accepted.body);
  assert.equal(editor.start, cursor);
  q.enqueueNote(state, { ...editor.note, body: editor.note.body.replace('Tea', 'Tea bags') }, editor.base);
  assert.deepEqual(state.pending[note().id].base, accepted);
  assert.equal(state.pending[note().id].note.body.includes('Remote lamp'), true);
  assert.equal(q.editorAfterAcknowledgement(state, [], { id: note().id, field: 'body', value: 'Draft', start: 5, end: 5 }), null);
});
