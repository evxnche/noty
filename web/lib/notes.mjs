import { randomUUID } from 'node:crypto';
import { mergeNoteBody } from '../public/note-text.mjs';
export { mergeNoteBody } from '../public/note-text.mjs';

export const NOTE_FIELDS = ['title', 'body', 'archived', 'deleted'];
const keys = ['id', ...NOTE_FIELDS, 'version', 'taskIds'];
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const identity = id => id.toLowerCase();
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const sameId = (a, b) => identity(a) === identity(b);
const clone = note => ({ ...note, taskIds: [...note.taskIds] });

export class NoteError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export function validateNote(note) {
  if (!object(note) || Object.keys(note).length !== keys.length || keys.some(field => !Object.hasOwn(note, field))) throw new NoteError(400, 'Invalid note fields.');
  if (typeof note.id !== 'string' || !uuid.test(note.id)) throw new NoteError(400, 'Note identifiers must be UUIDs.');
  if (typeof note.title !== 'string' || note.title.length > 120 || /[\u0000-\u001f\u007f-\u009f]/.test(note.title)) throw new NoteError(400, 'Note title must contain at most 120 characters without control characters.');
  if (typeof note.body !== 'string' || note.body.length > 65_536) throw new NoteError(400, 'Note body must contain at most 65536 UTF-16 units.');
  if (typeof note.archived !== 'boolean' || typeof note.deleted !== 'boolean' || !Number.isSafeInteger(note.version) || note.version < 0) throw new NoteError(400, 'Invalid note flags or version.');
  if (!Array.isArray(note.taskIds) || note.taskIds.length > 65_536 || note.taskIds.some(id => typeof id !== 'string' || !uuid.test(id)) || new Set(note.taskIds.map(identity)).size !== note.taskIds.length) throw new NoteError(400, 'Invalid note task identifiers.');
  return clone(note);
}

export function validateNoteChanges(body) {
  if (!object(body) || Object.keys(body).some(key => !['changes', 'deskPalId'].includes(key)) || !Array.isArray(body.changes) || body.changes.length > 256) throw new NoteError(400, 'Expected up to 256 note changes.');
  if (Object.hasOwn(body, 'deskPalId') && body.deskPalId !== null && (typeof body.deskPalId !== 'string' || !uuid.test(body.deskPalId))) throw new NoteError(400, 'Desk Pal note identifier must be a UUID or null.');
  const ids = new Set();
  const changes = body.changes.map(change => {
    if (!object(change) || Object.keys(change).length !== 2 || !Object.hasOwn(change, 'note') || !Object.hasOwn(change, 'base')) throw new NoteError(400, 'Each change requires note and base.');
    const note = validateNote(change.note);
    const base = change.base === null ? null : validateNote(change.base);
    if (base && !sameId(base.id, note.id)) throw new NoteError(400, 'Note and base identifiers must match.');
    if (ids.has(identity(note.id))) throw new NoteError(400, 'A note can occur only once per request.');
    ids.add(identity(note.id));
    return { note, base };
  });
  return { changes, ...(Object.hasOwn(body, 'deskPalId') ? { deskPalId: body.deskPalId } : {}) };
}

function bump(note, current) {
  if (current?.version === Number.MAX_SAFE_INTEGER) throw new NoteError(503, 'Note version capacity reached.');
  return { ...note, version: current ? current.version + 1 : 1 };
}

export function mergeNoteRecords(notes, changes) {
  const records = new Map(notes.map(note => [identity(note.id), clone(note)]));
  const conflicts = [];
  for (const { note, base } of changes) {
    const current = records.get(identity(note.id));
    if (!current) {
      if (base) throw new NoteError(409, 'The note base does not exist. Refresh before retrying.');
      if (records.size >= 256) throw new NoteError(409, 'Note storage is full. Existing notes are preserved.');
      records.set(identity(note.id), bump({ ...note, taskIds: [] }, null));
      continue;
    }
    if (!base) {
      if (!NOTE_FIELDS.every(field => note[field] === current[field])) conflicts.push({ id: current.id, note: clone(current) });
      continue;
    }
    if (base.version > current.version) throw new NoteError(400, 'Note base version is ahead of the server.');
    const edits = NOTE_FIELDS.filter(field => note[field] !== base[field]);
    const desired = clone(current);
    let conflict = current.deleted && !note.deleted && edits.length > 0;
    for (const field of edits) {
      if (current[field] === base[field] || current[field] === note[field]) desired[field] = note[field];
      else if (field === 'body') {
        const merged = mergeNoteBody(base.body, current.body, note.body);
        if (merged === null) conflict = true;
        else desired.body = merged;
      } else conflict = true;
    }
    if (conflict) conflicts.push({ id: current.id, note: clone(current) });
    else if (NOTE_FIELDS.some(field => desired[field] !== current[field])) records.set(identity(note.id), validateNote(bump(desired, current)));
  }
  return { notes: [...records.values()], conflicts };
}

function heading(line) {
  const match = /^ {0,3}(#{1,6})[ \t]+(.+?)[ \t]*$/.exec(line);
  return match && { level: match[1].length, name: match[2].replace(/[ \t]+#+$/, '').trim().toLowerCase() };
}

/** Line indices and formatting are retained so task edits never rebuild note text. */
export function taskRows(note, deskPalId) {
  if (note.archived || note.deleted) return [];
  const deskPal = deskPalId !== null && deskPalId !== undefined && sameId(note.id, deskPalId);
  const rows = [];
  let todo = false, fence = null;
  const lines = note.body.split('\n');
  for (let line = 0; line < lines.length; line++) {
    const ending = lines[line].endsWith('\r') ? '\r' : '';
    const raw = ending ? lines[line].slice(0, -1) : lines[line];
    const marker = /^ {0,3}(`{3,}|~{3,})/.exec(raw);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length) fence = null;
      continue;
    }
    if (fence) continue;
    const header = heading(raw);
    if (header) { todo = header.level === 1 && ['to-do', 'todo', 'to do'].includes(header.name); continue; }
    if (deskPal && !todo) continue;
    let kind, prefix, suffix, middle = ' ', text, completed = false;
    const native = /^(\s*(?:[-*+]\s+)?)([☐☑])(\s*)(.*?)(\s*)$/.exec(raw);
    const checkbox = /^(\s*(?:[-*+]\s+)?\[)([ xX])(\]\s*)(.*?)(\s*)$/.exec(raw);
    if (native) {
      kind = 'native'; prefix = native[1]; middle = native[3]; suffix = native[5]; text = native[4].trim(); completed = native[2] === '☑';
    } else if (checkbox) {
      kind = 'checkbox'; prefix = checkbox[1]; middle = checkbox[3]; suffix = checkbox[5]; text = checkbox[4].trim(); completed = checkbox[2].toLowerCase() === 'x';
    } else if (deskPal) {
      const bullet = /^(\s*[-*+]\s+)(.*?)(\s*)$/.exec(raw);
      const plain = /^(\s*)(.*?)(\s*)$/.exec(raw);
      kind = bullet ? 'bullet' : 'plain';
      const match = bullet || plain;
      prefix = match[1]; text = match[2].trim(); suffix = match[3];
    } else continue;
    if (!text) continue;
    if (text.length > 2000) throw new NoteError(400, 'Each task line must contain at most 2000 UTF-16 units.');
    rows.push({ line, text, completed, kind, prefix, middle, suffix, ending, position: rows.length });
  }
  return rows;
}

function sameTask(a, b) {
  return sameId(a.noteId, b.noteId) && ['listTitle', 'text', 'completed', 'position', 'deleted'].every(field => a[field] === b[field]);
}

export function projectNotes(snapshot, notes, deskPalId, previousNotes = snapshot.notes || [], preservePositions = false) {
  const tasks = new Map(snapshot.tasks.map(task => [identity(task.id), { ...task }]));
  const previous = new Map(previousNotes.map(note => [identity(note.id), note]));
  const projected = [];
  for (const original of notes) {
    const note = clone(original);
    const old = previous.get(identity(note.id));
    const rows = taskRows(note, deskPalId);
    const oldRows = old ? taskRows(old, snapshot.deskPalId) : [];
    const sameRows = old && oldRows.length === rows.length && rows.every((row, i) => row.text === oldRows[i].text && row.completed === oldRows[i].completed);
    const retainMapping = preservePositions || sameRows;
    const candidates = [...tasks.values()].filter(task => sameId(task.noteId, note.id) && !task.deleted)
      .sort((a, b) => a.position - b.position || a.id.localeCompare(b.id));
    const unused = new Set(candidates.map(task => identity(task.id)));
    const assigned = new Map();
    if (retainMapping) {
      // The legacy bridge just rewrote exact mapped lines; trust that mapping for duplicates.
      for (const row of rows) {
        const mapped = note.taskIds[row.position];
        const task = mapped && tasks.get(identity(mapped));
        if (task && unused.has(identity(task.id)) && task.text === row.text && task.completed === row.completed) {
          assigned.set(row.position, task); unused.delete(identity(task.id));
        }
      }
    }
    // Match text before position so inserting headers/tasks cannot rename existing identities.
    for (const exactCompletion of [true, false]) {
      for (const row of rows) {
        if (assigned.has(row.position)) continue;
        const match = candidates.filter(task => unused.has(identity(task.id)) && task.text === row.text && (!exactCompletion || task.completed === row.completed))
          .sort((a, b) => Math.abs(a.position - row.position) - Math.abs(b.position - row.position))[0];
        if (match) { assigned.set(row.position, match); unused.delete(identity(match.id)); }
      }
    }
    if (old) {
      for (const row of rows) {
        if (assigned.has(row.position)) continue;
        const mapped = old.taskIds[row.position];
        const match = mapped && tasks.get(identity(mapped));
        if (match && unused.has(identity(match.id))) { assigned.set(row.position, match); unused.delete(identity(match.id)); }
      }
    }
    note.taskIds = [];
    for (const row of rows) {
      const current = assigned.get(row.position);
      const task = { id: current?.id || randomUUID(), noteId: current?.noteId || note.id, listTitle: note.title.trim() || 'Tasks', text: row.text, completed: row.completed, position: retainMapping && current ? current.position : row.position, deleted: false, version: current?.version || 1 };
      if (current && !sameTask(task, current)) {
        if (current.version === Number.MAX_SAFE_INTEGER) throw new NoteError(503, 'Task version capacity reached.');
        task.version++;
      }
      tasks.set(identity(task.id), task);
      note.taskIds.push(task.id);
    }
    // Only published, managed identities can be removed by a document edit.
    // The first publication must not tombstone older tasks absent from this upload.
    for (const id of old?.taskIds || []) {
      const task = tasks.get(identity(id));
      if (task && !task.deleted && !note.taskIds.some(mapped => sameId(mapped, id))) {
        if (task.version === Number.MAX_SAFE_INTEGER) throw new NoteError(503, 'Task version capacity reached.');
        tasks.set(identity(id), { ...task, deleted: true, version: task.version + 1 });
      }
    }
    projected.push(note);
  }
  return { tasks: [...tasks.values()], notes: projected, deskPalId };
}

function editedLine(row, task) {
  let prefix = row.prefix;
  if (row.kind === 'native') return `${prefix}${task.completed ? '☑' : '☐'}${row.middle}${task.text}${row.suffix}${row.ending}`;
  if (row.kind === 'checkbox') return `${prefix}${task.completed ? 'x' : ' '}${row.middle}${task.text}${row.suffix}${row.ending}`;
  if (task.completed !== row.completed) prefix += row.kind === 'plain' ? '- [x] ' : '[x] ';
  return `${prefix}${task.text}${row.suffix}${row.ending}`;
}

function insertTask(note, task, deskPalId) {
  const rows = taskRows(note, deskPalId);
  const lines = note.body.split('\n');
  const ending = note.body.includes('\r\n') ? '\r' : '';
  const selected = deskPalId && sameId(note.id, deskPalId);
  const before = rows.find(row => row.position >= task.position);
  let line = before?.line;
  if (line === undefined && selected) {
    const start = lines.findIndex(raw => { const h = heading(raw.replace(/\r$/, '')); return h?.level === 1 && ['to-do', 'todo', 'to do'].includes(h.name); });
    if (start < 0) {
      if (lines.at(-1) === '') lines.pop();
      if (note.body && lines.length) lines.push(ending);
      lines.push(`# to-do${ending}`);
      line = lines.length;
    } else {
      line = lines.findIndex((raw, i) => i > start && heading(raw.replace(/\r$/, '')));
      if (line < 0) line = lines.length;
      while (line > start + 1 && !lines[line - 1].trim()) line--;
    }
  }
  if (line === undefined) line = rows.length ? rows.at(-1).line + 1 : lines.length;
  if (line === lines.length && lines.at(-1) === '') line--;
  lines.splice(line, 0, `${task.completed ? '☑' : '☐'} ${task.text}${ending}`);
  const index = rows.filter(row => row.line < line).length;
  note.taskIds.splice(index, 0, task.id);
  note.body = lines.join('\n');
}

/** Apply legacy task writes to note text inside the same storage transaction. */
export function bridgeLegacyTasks(snapshot, mergedTasks) {
  const deskPalId = snapshot.deskPalId || null;
  const notes = (snapshot.notes || []).map(clone);
  const docs = new Map(notes.map(note => [identity(note.id), note]));
  const before = new Map(snapshot.tasks.map(task => [identity(task.id), task]));
  const after = new Map(mergedTasks.map(task => [identity(task.id), task]));
  const changedNotes = new Set();
  for (const task of mergedTasks) {
    const old = before.get(identity(task.id));
    if (old && sameTask(task, old)) continue;
    const source = old && docs.get(identity(old.noteId));
    const target = docs.get(identity(task.noteId));
    if (target && (target.deleted || target.archived) && !task.deleted) throw new NoteError(409, 'That note is archived or deleted. Refresh before editing its tasks.');
    const sourceIndex = source?.taskIds.findIndex(id => sameId(id, task.id)) ?? -1;
    if (source && sourceIndex >= 0) {
      const rows = taskRows(source, deskPalId);
      const row = rows[sourceIndex];
      if (!row) throw new NoteError(503, 'Task mapping is unavailable. Existing note text is preserved.');
      const lines = source.body.split('\n');
      if (task.deleted || !sameId(old.noteId, task.noteId)) {
        lines.splice(row.line, 1);
        source.taskIds.splice(sourceIndex, 1);
      } else lines[row.line] = editedLine(row, task);
      source.body = lines.join('\n');
      changedNotes.add(identity(source.id));
    }
    if (!task.deleted && target) {
      if (!target.taskIds.some(id => sameId(id, task.id))) insertTask(target, task, deskPalId);
      if (task.listTitle !== (target.title.trim() || 'Tasks')) target.title = task.listTitle;
      changedNotes.add(identity(target.id));
    }
  }
  for (const note of notes) if (changedNotes.has(identity(note.id))) {
    const rows = taskRows(note, deskPalId);
    const lines = note.body.split('\n');
    const rowById = new Map(note.taskIds.map((id, i) => [identity(id), lines[rows[i]?.line]]));
    const ordered = note.taskIds.map(id => after.get(identity(id))).filter(Boolean)
      .sort((a, b) => a.position - b.position || a.id.localeCompare(b.id));
    if (ordered.length === rows.length) {
      for (let i = 0; i < rows.length; i++) lines[rows[i].line] = rowById.get(identity(ordered[i].id));
      note.body = lines.join('\n');
      note.taskIds = ordered.map(task => task.id);
    }
    validateNote(note);
    const original = (snapshot.notes || []).find(item => sameId(item.id, note.id));
    if (NOTE_FIELDS.some(field => note[field] !== original[field]) || JSON.stringify(note.taskIds) !== JSON.stringify(original.taskIds)) note.version = bump(note, original).version;
  }
  // Re-project changed text/title and normalize positions without losing unrelated records.
  return projectNotes({ ...snapshot, tasks: mergedTasks }, notes, deskPalId, notes, true);
}

export function mergeNotesSnapshot(snapshot, request) {
  const merged = mergeNoteRecords(snapshot.notes || [], request.changes);
  let deskPalId = Object.hasOwn(request, 'deskPalId') ? request.deskPalId : snapshot.deskPalId || null;
  if (deskPalId !== null) {
    const selected = merged.notes.find(note => sameId(note.id, deskPalId));
    if (!selected) throw new NoteError(400, 'Desk Pal must refer to a published note.');
    deskPalId = selected.id;
  }
  const projected = projectNotes(snapshot, merged.notes, deskPalId);
  const changed = JSON.stringify(projected.notes) !== JSON.stringify(snapshot.notes || [])
    || JSON.stringify(projected.tasks) !== JSON.stringify(snapshot.tasks)
    || deskPalId !== (snapshot.deskPalId || null);
  return { ...projected, conflicts: merged.conflicts, changed };
}
