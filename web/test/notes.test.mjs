import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createLocalServer } from '../server.mjs';
import { createFileStore } from '../lib/sync.mjs';

const key = 'noty-notes-private-test-key-32-characters';
const noteId = 'B0000000-0000-4000-8000-000000000001';
const otherId = 'B0000000-0000-4000-8000-000000000002';
const doc = (extra = {}) => ({ id: noteId, title: 'Desk Pal', body: '# to-do\n- [ ] Buy milk\n\n# idea\n- Lamp\n\n# building\nRobot\n\n# testing\n\n# shift\nClock', archived: false, deleted: false, version: 0, taskIds: [], ...extra });
const task = (extra = {}) => ({ id: 'A0000000-0000-4000-8000-000000000001', noteId, listTitle: 'Desk Pal', text: 'Buy milk', completed: false, deleted: false, position: 0, version: 0, ...extra });

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'noty-notes-'));
  const path = join(directory, 'snapshot.json');
  const store = createFileStore(path);
  const server = createLocalServer({ token: key, store });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true }); });
  async function request(route = 'notes', body, auth = key) {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/api/${route}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { Authorization: `Bearer ${auth}`, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const text = await response.text();
    let parsed; try { parsed = JSON.parse(text); } catch { parsed = { error: text }; }
    return { status: response.status, headers: response.headers, body: parsed };
  }
  const publish = async (note = doc(), base = null, deskPalId = noteId) => request('notes', { changes: [{ note, base }], deskPalId });
  return { request, publish, store, path };
}

test('notes endpoint is private and starts empty without caching', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('notes', undefined, 'wrong')).status, 401);
  const response = await f.request();
  assert.equal(response.status, 200);
  assert.deepEqual(response.body, { notes: [], conflicts: [], deskPalId: null });
  assert.match(response.headers.get('cache-control'), /no-store/);
});

test('first publication preserves legacy task IDs, versions and unpublished notes', async t => {
  const f = await fixture(t);
  const original = (await f.request('sync', { changes: [
    { task: task(), base: null },
    { task: task({ id: 'A0000000-0000-4000-8000-000000000002', noteId: otherId, listTitle: 'Work', text: 'Report' }), base: null },
  ] })).body.tasks;
  const result = await f.publish();
  assert.equal(result.status, 200);
  assert.equal(result.body.notes[0].version, 1);
  assert.deepEqual(result.body.notes[0].taskIds, [task().id]);
  assert.deepEqual((await f.request('sync')).body.tasks, original);
  assert.deepEqual((await f.publish()).body, result.body);
  const snapshot = JSON.parse(await readFile(f.path, 'utf8'));
  assert.equal(snapshot.deskPalId, noteId);
  assert.equal(snapshot.notes.length, 1);
  assert.equal(snapshot.tasks.length, 2);
});

test('first native-glyph publication keeps all 16 legacy identities and completion flags', async t => {
  const f = await fixture(t);
  const original = [];
  const changes = [];
  for (let i = 0; i < 16; i++) {
    const record = task({ id: `A0000000-0000-4000-8000-${String(i + 1).padStart(12, '0')}`, noteId: i < 3 ? noteId : otherId, listTitle: i < 3 ? 'Desk Pal' : 'Work', text: `Task ${i}`, completed: i % 2 === 0, position: i < 3 ? i : i - 3 });
    original.push({ ...record, version: 1 }); changes.push({ task: record, base: null });
  }
  await f.request('sync', { changes });
  const body = tasks => tasks.map(task => `${task.completed ? '☑' : '☐'} ${task.text}`).join('\n');
  const published = await f.request('notes', { changes: [
    { note: doc({ body: '# to-do\n' + body(original.slice(0, 3)) + '\n# idea\nLamp' }), base: null },
    { note: doc({ id: otherId, title: 'Work', body: 'Context\n' + body(original.slice(3)) }), base: null },
  ], deskPalId: noteId });
  assert.equal(published.status, 200);
  assert.deepEqual((await f.request('sync')).body.tasks, original);
  assert.deepEqual(published.body.notes.find(note => note.id === noteId).taskIds, original.slice(0, 3).map(task => task.id));
  assert.deepEqual(published.body.notes.find(note => note.id === otherId).taskIds, original.slice(3).map(task => task.id));
  const base = original[1];
  await f.request('sync', { changes: [{ task: { ...base, completed: true, text: 'Renamed native task' }, base }] });
  const deskPal = (await f.request()).body.notes.find(note => note.id === noteId);
  assert.equal(deskPal.body, '# to-do\n☑ Task 0\n☑ Renamed native task\n☑ Task 2\n# idea\nLamp');
});

test('Desk Pal tasks come only from to-do, other notes only from checkboxes', async t => {
  const f = await fixture(t);
  const body = '# to-do\nPlain\n* Bullet\n+ [X] Done\n\n```\nHidden code\n```\n\n# idea\n- [ ] A project\n# building\nThing\n# testing\nTest\n# shipped\nShip';
  const result = await f.publish(doc({ body }));
  assert.equal(result.status, 200);
  await f.publish(doc({ id: otherId, title: 'Work', body: '# Work\nPlain context\n- [ ] Report\n- [x] Email' }), null);
  const tasks = (await f.request('sync')).body.tasks.filter(task => !task.deleted);
  assert.deepEqual(tasks.filter(task => task.noteId === noteId).map(task => [task.text, task.completed]), [['Plain', false], ['Bullet', false], ['Done', true]]);
  assert.deepEqual(tasks.filter(task => task.noteId === otherId).map(task => task.text), ['Report', 'Email']);
});

test('note edits keep task identity and project edits do not alter unrelated tasks', async t => {
  const f = await fixture(t);
  const base = (await f.publish()).body.notes[0];
  const before = (await f.request('sync')).body.tasks;
  const edited = (await f.publish({ ...base, body: base.body.replace('Lamp', 'Lamp v2') }, base)).body.notes[0];
  assert.deepEqual((await f.request('sync')).body.tasks, before);
  const renamed = (await f.publish({ ...edited, body: edited.body.replace('Buy milk', 'Buy oat milk') }, edited)).body.notes[0];
  assert.deepEqual(renamed.taskIds, base.taskIds);
  const updated = (await f.request('sync')).body.tasks[0];
  assert.equal(updated.id, before[0].id);
  assert.equal(updated.text, 'Buy oat milk');
  assert.equal(updated.version, before[0].version + 1);
});

test('legacy completion, rename and insertion update exact note lines preserving headers', async t => {
  const f = await fixture(t);
  await f.publish(doc({ body: 'Context\r\n# to-do\r\n  - Buy milk  \r\n\r\n# idea\r\nLamp\r\n# testing\r\nRobot\r\n' }));
  const base = (await f.request('sync')).body.tasks[0];
  const completed = await f.request('sync', { changes: [{ task: { ...base, text: 'Buy tea', completed: true }, base }] });
  assert.equal(completed.status, 200);
  let note = (await f.request()).body.notes[0];
  assert.equal(note.body, 'Context\r\n# to-do\r\n  - [x] Buy tea  \r\n\r\n# idea\r\nLamp\r\n# testing\r\nRobot\r\n');
  assert.equal(note.version, 2);
  const created = task({ id: 'A0000000-0000-4000-8000-000000000099', text: 'Board task', position: 1 });
  await f.request('sync', { changes: [{ task: created, base: null }] });
  note = (await f.request()).body.notes[0];
  assert.ok(note.body.indexOf('☐ Board task') < note.body.indexOf('# idea'));
  assert.deepEqual(note.taskIds, [base.id, created.id]);
  const added = (await f.request('sync')).body.tasks.find(task => task.id === created.id);
  await f.request('sync', { changes: [{ task: { ...added, deleted: true }, base: added }] });
  note = (await f.request()).body.notes[0];
  assert.equal(note.body.includes('Board task'), false);
  assert.equal(note.body.includes('# testing\r\nRobot'), true);
  assert.deepEqual(note.taskIds, [base.id]);
});

test('task moves and note title changes bridge across all affected records', async t => {
  const f = await fixture(t);
  await f.publish();
  await f.publish(doc({ id: otherId, title: 'Work', body: 'Work context\n- [ ] Report\nTail' }), null);
  const base = (await f.request('sync')).body.tasks.find(task => task.noteId === noteId);
  await f.request('sync', { changes: [{ task: { ...base, noteId: otherId, listTitle: 'Work', position: 1 }, base }] });
  let docs = (await f.request()).body.notes;
  assert.equal(docs.find(note => note.id === noteId).body.includes('Buy milk'), false);
  assert.equal(docs.find(note => note.id === otherId).body.includes('☐ Buy milk'), true);
  const work = docs.find(note => note.id === otherId);
  await f.publish({ ...work, title: 'Work notes' }, work);
  assert.ok((await f.request('sync')).body.tasks.filter(task => task.noteId === otherId && !task.deleted).every(task => task.listTitle === 'Work notes'));
});

test('disjoint note fields and line ranges merge, overlapping text remains a conflict', async t => {
  const f = await fixture(t);
  const base = (await f.publish()).body.notes[0];
  await f.publish({ ...base, body: base.body.replace('Lamp', 'Desk lamp') }, base);
  const merged = await f.publish({ ...base, title: 'Desk Pal v2', body: base.body.replace('Buy milk', 'Buy tea') }, base);
  assert.deepEqual(merged.body.conflicts, []);
  const remote = merged.body.notes[0];
  assert.equal(remote.title, 'Desk Pal v2');
  assert.equal(remote.body, base.body.replace('Lamp', 'Desk lamp').replace('Buy milk', 'Buy tea'));
  const conflict = await f.publish({ ...base, title: 'Desk Pal local', body: base.body.replace('Buy milk', 'Buy coffee') }, base);
  assert.deepEqual(conflict.body.conflicts, [{ id: noteId, note: remote }]);
  assert.deepEqual(conflict.body.notes, [remote]);
});

test('concurrent task and project edits share CAS without dropping either', async t => {
  const f = await fixture(t);
  const base = (await f.publish()).body.notes[0];
  const taskBase = (await f.request('sync')).body.tasks[0];
  const responses = await Promise.all([
    f.publish({ ...base, body: base.body.replace('Lamp', 'New lamp') }, base),
    f.request('sync', { changes: [{ task: { ...taskBase, completed: true }, base: taskBase }] }),
  ]);
  assert.ok(responses.every(response => response.status === 200 && response.body.conflicts.length === 0));
  const note = (await f.request()).body.notes[0];
  assert.ok(note.body.includes('- [x] Buy milk'));
  assert.ok(note.body.includes('New lamp'));
});

test('concurrent independent note creates stay durable and cannot evict tasks', async t => {
  const f = await fixture(t);
  await f.publish();
  const replies = await Promise.all(Array.from({ length: 12 }, (_, i) => f.publish(doc({ id: `B0000000-0000-4000-8000-${String(i + 2).padStart(12, '0')}`, title: `Note ${i}`, body: `Context ${i} 🧑🏽‍💻\n- [ ] Task ${i}` }), null)));
  assert.ok(replies.every(response => response.status === 200));
  assert.equal((await f.request()).body.notes.length, 13);
  assert.equal((await f.request('sync')).body.tasks.filter(task => !task.deleted).length, 13);
});

test('note tombstones persist and stale edits cannot restore them', async t => {
  const f = await fixture(t);
  const base = (await f.publish()).body.notes[0];
  const removed = await f.publish({ ...base, deleted: true }, base);
  assert.equal(removed.body.notes[0].deleted, true);
  assert.equal((await f.request('sync')).body.tasks[0].deleted, true);
  assert.deepEqual((await f.publish({ ...base, deleted: true }, base)).body, removed.body);
  const stale = await f.publish({ ...base, body: base.body + '\nLate edit' }, base);
  assert.equal(stale.body.conflicts.length, 1);
  assert.equal(stale.body.notes[0].deleted, true);
});

test('invalid docs, duplicate IDs and forged task mappings are bounded without data loss', async t => {
  const f = await fixture(t);
  for (const invalid of [doc({ body: 'x'.repeat(65537) }), doc({ id: '../bad' }), doc({ title: 'x'.repeat(121) }), doc({ archived: 1 }), doc({ deleted: 0 }), doc({ version: -1 }), doc({ taskIds: ['bad'] }), doc({ extra: true })]) {
    assert.equal((await f.publish(invalid)).status, 400);
  }
  assert.equal((await f.request('notes', { changes: [{ note: doc(), base: null }, { note: doc({ id: noteId.toLowerCase() }), base: null }] })).status, 400);
  const note = (await f.publish(doc({ taskIds: ['A0000000-0000-4000-8000-000000000099'] }))).body.notes[0];
  assert.notEqual(note.taskIds[0], 'A0000000-0000-4000-8000-000000000099');
  const raw = await readFile(f.path, 'utf8');
  assert.equal((await f.publish({ ...note, body: '😀'.repeat(32769) }, note)).status, 400);
  assert.equal(await readFile(f.path, 'utf8'), raw);
});

test('legacy array CAS preserves all published note fields and selected role', async t => {
  const f = await fixture(t);
  const note = (await f.publish()).body.notes[0];
  const snapshot = await f.store.read();
  assert.equal(await f.store.compareAndSwap(snapshot, snapshot.tasks), true);
  assert.deepEqual((await f.request()).body, { notes: [note], conflicts: [], deskPalId: noteId });
});

test('corrupt stored note records fail closed without a client validation status or reset', async t => {
  const f = await fixture(t);
  await f.publish();
  const snapshot = JSON.parse(await readFile(f.path, 'utf8'));
  snapshot.notes[0].body = null;
  const corrupt = JSON.stringify(snapshot);
  await writeFile(f.path, corrupt);
  const result = await f.request();
  assert.equal(result.status, 503);
  assert.equal(await readFile(f.path, 'utf8'), corrupt);
});

test('legacy task reordering changes only task lines and retains identities', async t => {
  const f = await fixture(t);
  await f.publish(doc({ body: '# to-do\n- [ ] First\nContext task\n- [ ] Last\n\n# idea\nLamp' }));
  const before = (await f.request('sync')).body.tasks;
  const last = before.find(task => task.text === 'Last');
  await f.request('sync', { changes: [{ task: { ...last, position: -1 }, base: last }] });
  const note = (await f.request()).body.notes[0];
  assert.equal(note.body, '# to-do\n- [ ] Last\n- [ ] First\nContext task\n\n# idea\nLamp');
  assert.deepEqual(note.taskIds, [last.id, ...before.filter(task => task.id !== last.id).map(task => task.id)]);
});

test('duplicate-text legacy task reordering keeps the exact moved identity', async t => {
  const f = await fixture(t);
  const base = (await f.publish(doc({ body: '# to-do\n☐ Duplicate\n☐ Duplicate\n# idea\nLamp' }))).body.notes[0];
  const tasks = (await f.request('sync')).body.tasks;
  const moved = tasks.find(task => task.id === base.taskIds[1]);
  const change = { changes: [{ task: { ...moved, position: -1 }, base: moved }] };
  await f.request('sync', change);
  const after = (await f.request()).body.notes[0];
  assert.deepEqual(after.taskIds, [base.taskIds[1], base.taskIds[0]]);
  assert.equal((await f.request('sync', change)).body.conflicts.length, 0);
  const records = (await f.request('sync')).body.tasks;
  const projectEdit = (await f.publish({ ...after, body: after.body.replace('Lamp', 'Lamp v2') }, after)).body.notes[0];
  assert.deepEqual(projectEdit.taskIds, after.taskIds);
  assert.deepEqual((await f.request('sync')).body.tasks, records);
});

test('archiving a published note retains its fulltext and all task tombstones', async t => {
  const f = await fixture(t);
  const base = (await f.publish()).body.notes[0];
  const archived = (await f.publish({ ...base, archived: true }, base)).body.notes[0];
  assert.equal(archived.body, base.body);
  assert.equal(archived.archived, true);
  assert.equal((await f.request('sync')).body.tasks[0].deleted, true);
});
