import { timingSafeEqual, randomUUID } from 'node:crypto';
import { readFile, writeFile, rename, mkdir, unlink } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { NoteError, validateNote, validateNoteChanges, mergeNotesSnapshot, bridgeLegacyTasks } from './notes.mjs';

export const MAX_BODY_BYTES = 1_048_576;
const fields = ['noteId', 'listTitle', 'text', 'completed', 'position', 'deleted'];
const recordKeys = ['id', ...fields, 'version'];
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const fileQueues = new Map();

class RequestError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

function object(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function identifier(value) { return typeof value === 'string' && uuid.test(value); }
function key(task) { return task.id.toLowerCase(); }
function same(field, left, right) { return field === 'noteId' ? left.toLowerCase() === right.toLowerCase() : left === right; }

function validateTask(task) {
  if (!object(task) || Object.keys(task).length !== recordKeys.length || recordKeys.some(field => !Object.hasOwn(task, field))) throw new RequestError(400, 'Invalid task fields.');
  if (!identifier(task.id) || !identifier(task.noteId)) throw new RequestError(400, 'Task identifiers must be UUIDs.');
  if (typeof task.text !== 'string' || !task.text.trim() || task.text.length > 2000 || /[\r\n]/.test(task.text)) throw new RequestError(400, 'Task text must be one non-empty line of at most 2000 characters.');
  if (typeof task.listTitle !== 'string' || !task.listTitle.trim() || task.listTitle.length > 120 || /[\u0000-\u001f\u007f-\u009f]/.test(task.listTitle)) throw new RequestError(400, 'List title must contain 1 to 120 characters without control characters.');
  if (typeof task.completed !== 'boolean' || typeof task.deleted !== 'boolean') throw new RequestError(400, 'Invalid task flags.');
  if (typeof task.position !== 'number' || !Number.isFinite(task.position) || !Number.isSafeInteger(task.version) || task.version < 0) throw new RequestError(400, 'Invalid task position or version.');
  return { ...task };
}

export function validateChanges(body) {
  if (!object(body) || Object.keys(body).length !== 1 || !Array.isArray(body.changes) || body.changes.length > 250) throw new RequestError(400, 'Expected up to 250 task changes.');
  const ids = new Set();
  return body.changes.map(change => {
    if (!object(change) || Object.keys(change).length !== 2 || !Object.hasOwn(change, 'task') || !Object.hasOwn(change, 'base')) throw new RequestError(400, 'Each change requires task and base.');
    const task = validateTask(change.task);
    const base = change.base === null ? null : validateTask(change.base);
    if (base && key(base) !== key(task)) throw new RequestError(400, 'Task and base identifiers must match.');
    if (ids.has(key(task))) throw new RequestError(400, 'A task can occur only once per request.');
    ids.add(key(task));
    return { task, base };
  });
}

function sorted(tasks) {
  return tasks.sort((a, b) => a.noteId.localeCompare(b.noteId) || a.position - b.position || a.id.localeCompare(b.id));
}

export function mergeChanges(tasks, changes) {
  const records = new Map(tasks.map(task => [key(task), task]));
  const conflicts = [];
  let changed = false;
  for (const { task, base } of changes) {
    const current = records.get(key(task));
    if (!current) {
      if (base) throw new RequestError(409, 'The task base does not exist. Refresh before retrying.');
      records.set(key(task), { ...task, version: 1 });
      changed = true;
      continue;
    }
    if (!base) {
      if (!fields.every(field => same(field, task[field], current[field]))) conflicts.push({ id: task.id, task: current });
      continue;
    }
    if (base.version > current.version) throw new RequestError(400, 'Task base version is ahead of the server.');
    const edits = fields.filter(field => !same(field, task[field], base[field]));
    // Deletion is permanent: a client with a stale live record cannot restore it.
    if ((current.deleted && !task.deleted && edits.length) || edits.some(field => !same(field, current[field], base[field]) && !same(field, current[field], task[field]))) {
      conflicts.push({ id: task.id, task: current });
      continue;
    }
    const merged = { ...current };
    for (const field of edits) merged[field] = task[field];
    if (fields.some(field => !same(field, merged[field], current[field]))) {
      if (current.version === Number.MAX_SAFE_INTEGER) throw new RequestError(503, 'Task version capacity reached.');
      merged.version = current.version + 1;
      records.set(key(task), merged);
      changed = true;
    }
  }
  return { tasks: sorted([...records.values()]), conflicts, changed };
}

function decodeSnapshot(raw) {
  if (raw === null) return { revision: 0, tasks: [], notes: [], deskPalId: null, raw: '' };
  const value = JSON.parse(raw);
  if (!object(value) || !Number.isSafeInteger(value.revision) || value.revision < 0 || !Array.isArray(value.tasks)) throw new Error('Invalid persistent snapshot');
  let tasks;
  try { tasks = value.tasks.map(validateTask); }
  catch { throw new Error('Invalid persistent task records'); }
  if (tasks.some(task => task.version < 1) || new Set(tasks.map(key)).size !== tasks.length) throw new Error('Invalid persistent task records');
  let notes;
  try { notes = (value.notes ?? []).map(validateNote); }
  catch { throw new Error('Invalid persistent note records'); }
  if (notes.some(note => note.version < 1) || new Set(notes.map(note => key(note))).size !== notes.length) throw new Error('Invalid persistent notes');
  const deskPalId = value.deskPalId ?? null;
  if (deskPalId !== null && (!identifier(deskPalId) || !notes.some(note => key(note) === deskPalId.toLowerCase()))) throw new Error('Invalid Desk Pal note identifier');
  return { revision: value.revision, tasks, notes, deskPalId, raw };
}

function encodeSnapshot(snapshot, update) {
  if (snapshot.revision === Number.MAX_SAFE_INTEGER) throw new Error('Snapshot revision capacity reached');
  const fields = Array.isArray(update) ? { tasks: update, notes: snapshot.notes || [], deskPalId: snapshot.deskPalId || null } : update;
  return JSON.stringify({ revision: snapshot.revision + 1, tasks: fields.tasks, notes: fields.notes, deskPalId: fields.deskPalId });
}

async function withFileQueue(path, action) {
  const previous = fileQueues.get(path) ?? Promise.resolve();
  const operation = previous.catch(() => {}).then(action);
  fileQueues.set(path, operation);
  try { return await operation; }
  finally { if (fileQueues.get(path) === operation) fileQueues.delete(path); }
}

/** Persistent single-process adapter for a local development server. */
export function createFileStore(filePath) {
  const path = resolve(filePath);
  async function read() {
    try { return decodeSnapshot(await readFile(path, 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return decodeSnapshot(null); throw error; }
  }
  return {
    read,
    compareAndSwap(snapshot, tasks) {
      return withFileQueue(path, async () => {
        const current = await read();
        if (current.raw !== snapshot.raw) return false;
        await mkdir(dirname(path), { recursive: true, mode: 0o700 });
        const temporary = `${path}.${randomUUID()}.tmp`;
        try {
          await writeFile(temporary, encodeSnapshot(snapshot, tasks), { mode: 0o600, flag: 'wx' });
          await rename(temporary, path);
        } finally { await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
        return true;
      });
    }
  };
}

const compareScript = `local current = redis.call('GET', KEYS[1])
if (current or '') ~= ARGV[1] then return 0 end
redis.call('SET', KEYS[1], ARGV[2])
return 1`;

/** Redis EVAL makes snapshot compare-and-swap atomic across function instances. */
export function createRedisStore({ url, token, key: storageKey = 'noty:tasks:v1' }) {
  const endpoint = new URL(url);
  if (endpoint.protocol !== 'https:' && !(endpoint.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(endpoint.hostname))) throw new Error('Redis REST requires HTTPS');
  if (endpoint.username || endpoint.password || endpoint.search || endpoint.hash || !token || typeof token !== 'string') throw new Error('Invalid Redis configuration');
  async function command(parts) {
    const response = await fetch(endpoint, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(parts), signal: AbortSignal.timeout(10_000), redirect: 'error' });
    if (!response.ok) throw new Error('Redis request failed');
    const result = await response.json();
    if (result.error || !Object.hasOwn(result, 'result')) throw new Error('Redis command failed');
    return result.result;
  }
  return {
    async read() {
      const raw = await command(['GET', storageKey]);
      if (raw !== null && typeof raw !== 'string') throw new Error('Invalid Redis value');
      return decodeSnapshot(raw);
    },
    async compareAndSwap(snapshot, tasks) {
      return (await command(['EVAL', compareScript, 1, storageKey, snapshot.raw, encodeSnapshot(snapshot, tasks)])) === 1;
    }
  };
}

export function storeFromEnvironment(env) {
  const upstash = env.UPSTASH_REDIS_REST_URL || env.UPSTASH_REDIS_REST_TOKEN;
  const url = upstash ? env.UPSTASH_REDIS_REST_URL : env.KV_REST_API_URL;
  const token = upstash ? env.UPSTASH_REDIS_REST_TOKEN : env.KV_REST_API_TOKEN;
  if (url && token) return createRedisStore({ url, token, key: env.NOTY_SYNC_REDIS_KEY || 'noty:tasks:v1' });
  throw new RequestError(503, 'Durable sync storage is not configured.');
}

function authorized(header, token) {
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) return false;
  const actual = Buffer.from(header.slice(7));
  const expected = Buffer.from(token);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

async function requestBody(req) {
  if (!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'] ?? '')) throw new RequestError(415, 'Use application/json.');
  const contentLength = req.headers['content-length'];
  if (contentLength && Number(contentLength) > MAX_BODY_BYTES) throw new RequestError(413, 'Request body is too large.');
  if (req.body !== undefined) {
    const raw = typeof req.body === 'string' || Buffer.isBuffer(req.body) ? req.body.toString() : JSON.stringify(req.body);
    if (Buffer.byteLength(raw) > MAX_BODY_BYTES) throw new RequestError(413, 'Request body is too large.');
    try { return JSON.parse(raw); } catch { throw new RequestError(400, 'Invalid JSON.'); }
  }
  const chunks = [];
  let length = 0;
  for await (const chunk of req) {
    length += chunk.length;
    if (length > MAX_BODY_BYTES) throw new RequestError(413, 'Request body is too large.');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new RequestError(400, 'Invalid JSON.'); }
}

function createHandler({ token, store, env = process.env } = {}, notesAPI = false) {
  return async (req, res) => {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'private, no-store, max-age=0');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    const reply = (status, value) => { res.statusCode = status; res.end(JSON.stringify(value)); };
    try {
      const privateKey = token ?? env.NOTY_SYNC_TOKEN;
      if (typeof privateKey !== 'string' || privateKey.length < 32 || /[\r\n]/.test(privateKey)) throw new RequestError(503, 'Sync private key is not configured.');
      if (!authorized(req.headers.authorization, privateKey)) { res.setHeader('WWW-Authenticate', 'Bearer'); throw new RequestError(401, 'A valid private key is required.'); }
      if (!['GET', 'POST'].includes(req.method)) { res.setHeader('Allow', 'GET, POST'); throw new RequestError(405, 'Method not allowed.'); }
      const changes = req.method === 'POST' ? (notesAPI ? validateNoteChanges : validateChanges)(await requestBody(req)) : null;
      const storage = store ?? storeFromEnvironment(env);
      const response = result => notesAPI
        ? { notes: result.notes || [], conflicts: result.conflicts || [], deskPalId: result.deskPalId || null }
        : { tasks: sorted(result.tasks), conflicts: result.conflicts || [] };
      if (changes === null) return reply(200, response(await storage.read()));
      for (let attempt = 0; attempt < 30; attempt++) {
        const snapshot = await storage.read();
        const merged = notesAPI ? mergeNotesSnapshot(snapshot, changes) : mergeChanges(snapshot.tasks, changes);
        const update = !notesAPI && merged.changed ? bridgeLegacyTasks(snapshot, merged.tasks) : merged;
        if (!merged.changed || await storage.compareAndSwap(snapshot, update)) return reply(200, response({ ...update, conflicts: merged.conflicts }));
      }
      res.setHeader('Retry-After', '1');
      throw new RequestError(503, 'Sync is busy. Retry shortly.');
    } catch (error) {
      const requestError = error instanceof RequestError || error instanceof NoteError;
      reply(requestError ? error.status : 503, { error: requestError ? error.message : 'Sync storage is unavailable. Retry shortly.' });
    }
  };
}

export function createSyncHandler(options) { return createHandler(options); }
export function createNotesHandler(options) { return createHandler(options, true); }
