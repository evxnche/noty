import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const lib = await import('../lib/sync.mjs').catch(() => ({}));
const token = 'a-private-test-key-with-at-least-32-characters';
const task = (extra = {}) => ({ id: 'A0000000-0000-4000-8000-000000000001', noteId: 'B0000000-0000-4000-8000-000000000001', listTitle: 'Tasks', text: 'Buy milk', completed: false, position: 0, deleted: false, version: 0, ...extra });

function backend() {
  assert.equal(typeof lib.createSyncHandler, 'function', 'sync handler must be implemented');
  assert.equal(typeof lib.createFileStore, 'function', 'persistent file store must be implemented');
  return lib;
}

async function fixture(t, options = {}) {
  const api = backend();
  const directory = await mkdtemp(join(tmpdir(), 'noty-sync-'));
  const path = join(directory, 'tasks.json');
  const store = api.createFileStore(path);
  const server = createServer(api.createSyncHandler({ token, store, ...options }));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true }); });
  const url = `http://127.0.0.1:${server.address().port}/api/sync`;
  const request = async (changes, auth = token, extra = {}) => {
    const { headers, ...options } = extra;
    const response = await fetch(url, { method: changes === undefined ? 'GET' : 'POST', headers: { ...(auth ? { Authorization: `Bearer ${auth}` } : {}), ...(changes === undefined ? {} : { 'Content-Type': 'application/json' }), ...headers }, ...(changes === undefined ? {} : { body: JSON.stringify({ changes }) }), ...options });
    return { status: response.status, headers: response.headers, body: await response.json() };
  };
  return { api, directory, path, store, request, url };
}

test('GET starts empty and rejects unauthenticated access before storage', async t => {
  let reads = 0;
  const f = await fixture(t, { store: { read() { reads++; throw new Error('storage accessed'); } } });
  assert.equal((await f.request(undefined, null)).status, 401);
  assert.equal((await f.request(undefined, 'incorrect')).status, 401);
  assert.equal(reads, 0);
});

test('tasks persist and identical creation retries do not change version', async t => {
  const f = await fixture(t);
  assert.deepEqual((await f.request()).body, { tasks: [], conflicts: [] });
  const changes = [{ task: task(), base: null }];
  const created = await f.request(changes);
  assert.equal(created.status, 200);
  assert.equal(created.body.tasks[0].version, 1);
  assert.deepEqual((await f.request(changes)).body, created.body);
  const reopened = await f.api.createFileStore(f.path).read();
  assert.deepEqual(reopened.tasks, created.body.tasks);
  assert.equal((await stat(f.path)).mode & 0o777, 0o600);
  assert.equal(created.headers.get('cache-control').includes('no-store'), true);
});

test('disjoint offline edits merge without losing either field', async t => {
  const f = await fixture(t);
  const base = (await f.request([{ task: task(), base: null }])).body.tasks[0];
  await f.request([{ task: { ...base, text: 'Buy oat milk' }, base }]);
  const merged = await f.request([{ task: { ...base, completed: true }, base }]);
  assert.deepEqual(merged.body.conflicts, []);
  assert.equal(merged.body.tasks[0].text, 'Buy oat milk');
  assert.equal(merged.body.tasks[0].completed, true);
  assert.equal(merged.body.tasks[0].version, 3);
});

test('same-field conflict applies none of that task changes', async t => {
  const f = await fixture(t);
  const base = (await f.request([{ task: task(), base: null }])).body.tasks[0];
  const remote = (await f.request([{ task: { ...base, text: 'Remote edit' }, base }])).body.tasks[0];
  const conflict = await f.request([{ task: { ...base, text: 'Offline edit', completed: true }, base }]);
  assert.deepEqual(conflict.body.tasks, [remote]);
  assert.deepEqual(conflict.body.conflicts, [{ id: base.id, task: remote }]);
  assert.equal(conflict.body.tasks[0].completed, false);
});

test('same-field identical retries are idempotent', async t => {
  const f = await fixture(t);
  const base = (await f.request([{ task: task(), base: null }])).body.tasks[0];
  const changes = [{ task: { ...base, completed: true }, base }];
  const first = await f.request(changes);
  const retry = await f.request(changes);
  assert.deepEqual(retry.body, first.body);
  assert.equal(retry.body.tasks[0].version, 2);
});

test('an offline delete merges with a concurrent text edit and persists its tombstone', async t => {
  const f = await fixture(t);
  const base = (await f.request([{ task: task(), base: null }])).body.tasks[0];
  await f.request([{ task: { ...base, text: 'Updated before deletion' }, base }]);
  const deleted = await f.request([{ task: { ...base, deleted: true }, base }]);
  assert.equal(deleted.body.tasks[0].deleted, true);
  assert.equal(deleted.body.tasks[0].text, 'Updated before deletion');
  assert.equal((await f.api.createFileStore(f.path).read()).tasks[0].deleted, true);
  const stale = await f.request([{ task: { ...base, completed: true }, base }]);
  assert.equal(stale.body.conflicts.length, 1);
  assert.deepEqual(stale.body.tasks, deleted.body.tasks);
  const createRetry = await f.request([{ task: task(), base: null }]);
  assert.equal(createRetry.body.conflicts.length, 1);
  assert.equal(createRetry.body.tasks[0].deleted, true);
});

test('explicit resurrection of an acknowledged tombstone is rejected', async t => {
  const f = await fixture(t);
  const base = (await f.request([{ task: task({ deleted: true }), base: null }])).body.tasks[0];
  const result = await f.request([{ task: { ...base, deleted: false }, base }]);
  assert.equal(result.body.tasks[0].deleted, true);
  assert.equal(result.body.conflicts.length, 1);
});

test('conflicting task does not prevent an independent task update', async t => {
  const f = await fixture(t);
  const second = task({ id: 'a0000000-0000-4000-8000-000000000002', text: 'Walk' });
  const initial = (await f.request([{ task: task(), base: null }, { task: second, base: null }])).body.tasks;
  const base = initial.find(x => x.id === task().id);
  const other = initial.find(x => x.id === second.id);
  await f.request([{ task: { ...base, text: 'Remote' }, base }]);
  const result = await f.request([{ task: { ...base, text: 'Local' }, base }, { task: { ...other, completed: true }, base: other }]);
  assert.equal(result.body.conflicts.length, 1);
  assert.equal(result.body.tasks.find(x => x.id === second.id).completed, true);
});

test('concurrent independent creates remain durable', async t => {
  const f = await fixture(t);
  const replies = await Promise.all(Array.from({ length: 20 }, (_, i) => f.request([{ task: task({ id: `a0000000-0000-4000-8000-${String(i + 1).padStart(12, '0')}` }), base: null }])));
  assert.equal(replies.every(reply => reply.status === 200), true);
  assert.equal((await f.request()).body.tasks.length, 20);
});

test('concurrent same-field edits produce one success and one conflict', async t => {
  const f = await fixture(t);
  const base = (await f.request([{ task: task(), base: null }])).body.tasks[0];
  const replies = await Promise.all(['Left', 'Right'].map(text => f.request([{ task: { ...base, text }, base }])));
  assert.equal(replies.reduce((count, reply) => count + reply.body.conflicts.length, 0), 1);
  assert.equal((await f.request()).body.tasks[0].version, 2);
});

test('separate file adapters use compare-and-swap to reject stale writes', async t => {
  const f = await fixture(t);
  const other = f.api.createFileStore(f.path);
  const initial = await f.store.read();
  assert.equal(await f.store.compareAndSwap(initial, [task({ version: 1 })]), true);
  assert.equal(await other.compareAndSwap(initial, []), false);
  assert.equal((await other.read()).tasks.length, 1);
});

test('invalid task records and duplicate IDs are rejected without writes', async t => {
  const f = await fixture(t);
  const invalid = [task({ id: '../bad' }), task({ text: '' }), task({ text: 'a\nb' }), task({ text: 'a\rb' }), task({ text: 'x'.repeat(2001) }), task({ listTitle: 'x'.repeat(121) }), task({ listTitle: 'List\tname' }), task({ completed: 1 }), task({ deleted: 'false' }), task({ version: -1 }), task({ position: null }), task({ extra: true })];
  for (const bad of invalid) assert.equal((await f.request([{ task: bad, base: null }])).status, 400);
  assert.equal((await f.request([{ task: task(), base: null }, { task: task({ id: task().id.toLowerCase() }), base: null }])).status, 400);
  assert.equal((await f.request([{ task: task(), base: task({ id: 'a0000000-0000-4000-8000-000000000002' }) }])).status, 400);
  assert.deepEqual((await f.request()).body.tasks, []);
});

test('malformed JSON, wrong content type, and oversized bodies are rejected', async t => {
  const f = await fixture(t);
  assert.equal((await f.request([], token, { body: '{' })).status, 400);
  assert.equal((await f.request([], token, { body: JSON.stringify({ unexpected: true }) })).status, 400);
  assert.equal((await f.request([], token, { headers: { 'Content-Type': 'text/plain' } })).status, 415);
  assert.equal((await f.request([], token, { body: ' '.repeat(1_048_577) })).status, 413);
  assert.deepEqual((await f.request()).body.tasks, []);
});

test('missing token or durable production storage fails closed', async t => {
  const f = await fixture(t, { token: undefined, store: undefined, env: {} });
  assert.equal((await f.request()).status, 503);
  const g = await fixture(t, { store: undefined, env: { NOTY_SYNC_TOKEN: token } });
  assert.equal((await g.request()).status, 503);
});

test('API errors do not expose storage credentials or filesystem errors', async t => {
  const f = await fixture(t, { store: { async read() { throw new Error('secret-storage-password at /private/file'); } } });
  const result = await f.request();
  assert.equal(result.status, 503);
  assert.equal(JSON.stringify(result.body).includes('secret'), false);
});

test('unsupported methods have a bounded Allow header', async t => {
  const f = await fixture(t);
  const result = await f.request(undefined, token, { method: 'DELETE' });
  assert.equal(result.status, 405);
  assert.equal(result.headers.get('allow'), 'GET, POST');
});

test('Redis REST adapters send authenticated EVAL compare-and-swap and survive reopening', async t => {
  const api = backend();
  assert.equal(typeof api.createRedisStore, 'function');
  let value = null;
  const commands = [];
  const redis = createServer(async (req, res) => {
    assert.equal(req.headers.authorization, 'Bearer redis-private-key');
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    const command = JSON.parse(Buffer.concat(chunks).toString()); commands.push(command);
    let result;
    if (command[0] === 'GET') result = value;
    else {
      assert.equal(command[0], 'EVAL');
      assert.equal(command[2], 1);
      assert.match(command[1], /redis\.call\('GET'/);
      assert.match(command[1], /redis\.call\('SET'/);
      result = (value ?? '') === command[4] ? 1 : 0;
      if (result) value = command[5];
    }
    res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ result }));
  });
  await new Promise(resolve => redis.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => redis.close(resolve)));
  const config = { url: `http://127.0.0.1:${redis.address().port}`, token: 'redis-private-key', key: 'noty:test' };
  const first = api.createRedisStore(config);
  const second = api.createRedisStore(config);
  const original = await first.read();
  assert.equal(await first.compareAndSwap(original, [task({ version: 1 })]), true);
  assert.equal(await second.compareAndSwap(original, []), false);
  assert.deepEqual((await second.read()).tasks, [task({ version: 1 })]);
  assert.equal(commands.some(command => command[0] === 'EVAL'), true);
});

test('corrupt persistent storage is rejected instead of resetting records', async t => {
  const f = await fixture(t);
  await f.request([{ task: task(), base: null }]);
  const { writeFile } = await import('node:fs/promises');
  await writeFile(f.path, '{broken');
  assert.equal((await f.request()).status, 503);
  assert.equal(await readFile(f.path, 'utf8'), '{broken');
});

test('invalid records in well-formed storage fail as unavailable without overwriting', async t => {
  const f = await fixture(t);
  const { writeFile } = await import('node:fs/promises');
  const broken = JSON.stringify({ revision: 1, tasks: [task({ text: '', version: 1 })] });
  await writeFile(f.path, broken);
  assert.equal((await f.request()).status, 503);
  assert.equal(await readFile(f.path, 'utf8'), broken);
});

test('marketplace KV Redis environment aliases are accepted without local fallback', () => {
  const api = backend();
  assert.doesNotThrow(() => api.storeFromEnvironment({ KV_REST_API_URL: 'https://example.upstash.io', KV_REST_API_TOKEN: 'redis-private-key' }));
  assert.throws(() => api.storeFromEnvironment({ UPSTASH_REDIS_REST_URL: 'https://example.upstash.io', KV_REST_API_TOKEN: 'redis-private-key' }));
});

test('UUID case-only retries preserve creation identifiers and remain idempotent', async t => {
  const f = await fixture(t);
  const created = (await f.request([{ task: task(), base: null }])).body.tasks[0];
  const retried = await f.request([{ task: { ...created, id: created.id.toLowerCase(), noteId: created.noteId.toLowerCase() }, base: null }]);
  assert.deepEqual(retried.body, { tasks: [created], conflicts: [] });
});
