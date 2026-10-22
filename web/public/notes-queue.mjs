const fields = ['title', 'body', 'archived', 'deleted'];
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const copy = note => note === null ? null : { ...note, taskIds: [...note.taskIds] };

export function isNote(note) {
  return note && typeof note === 'object' && uuid.test(note.id)
    && typeof note.title === 'string' && note.title.length <= 120 && !/[\u0000-\u001f\u007f-\u009f]/.test(note.title)
    && typeof note.body === 'string' && note.body.length <= 65_536
    && typeof note.archived === 'boolean' && typeof note.deleted === 'boolean'
    && Number.isSafeInteger(note.version) && note.version >= 0
    && Array.isArray(note.taskIds) && note.taskIds.every(id => typeof id === 'string' && uuid.test(id))
    && new Set(note.taskIds.map(id => id.toLowerCase())).size === note.taskIds.length;
}

export function emptyNoteState() {
  return { notes: {}, pending: {}, conflicts: {}, nextRevision: 1, deskPalId: null };
}

export function restoreNoteState(saved) {
  const state = emptyNoteState();
  if (!saved || typeof saved !== 'object') return state;
  if (typeof saved.deskPalId === 'string' && uuid.test(saved.deskPalId)) state.deskPalId = saved.deskPalId;
  for (const note of Object.values(saved.notes || {})) if (isNote(note)) state.notes[note.id] = copy(note);
  for (const entry of Object.values(saved.pending || {})) {
    if (!entry || !isNote(entry.note) || !(entry.base === null || isNote(entry.base))) continue;
    if (entry.base && entry.base.id !== entry.note.id) continue;
    state.pending[entry.note.id] = { note: copy(entry.note), base: copy(entry.base), revision: state.nextRevision++ };
  }
  for (const conflict of Object.values(saved.conflicts || {})) {
    if (conflict && isNote(conflict.note) && state.pending[conflict.note.id]) state.conflicts[conflict.note.id] = { note: copy(conflict.note) };
  }
  return state;
}

export function enqueueNote(state, note, originalBase) {
  if (!isNote(note)) throw new Error('Invalid note.');
  const pending = state.pending[note.id];
  state.pending[note.id] = {
    note: copy(note), base: pending ? copy(pending.base) : copy(originalBase === undefined ? state.notes[note.id] || null : originalBase),
    revision: state.nextRevision++,
  };
}

export function visibleNotes(state) {
  const notes = { ...state.notes };
  for (const entry of Object.values(state.pending)) notes[entry.note.id] = entry.note;
  return Object.values(notes).filter(note => !note.deleted)
    .sort((a, b) => (b.id === state.deskPalId) - (a.id === state.deskPalId) || a.title.localeCompare(b.title) || a.id.localeCompare(b.id));
}

/** Keep a batch below the API's 1 MiB UTF-8 limit, including full original bases. */
export function prepareNoteChanges(state) {
  const changes = [];
  const encoder = new TextEncoder();
  for (const entry of Object.values(state.pending).filter(entry => !state.conflicts[entry.note.id])) {
    const next = { note: copy(entry.note), base: copy(entry.base), revision: entry.revision };
    const request = { changes: [...changes, next].map(({ note, base }) => ({ note, base })) };
    if (encoder.encode(JSON.stringify(request)).byteLength > 1_048_576) break;
    changes.push(next);
    if (changes.length === 256) break;
  }
  return changes;
}

export function applyNoteResponse(state, response, sent = []) {
  if (!response || !Array.isArray(response.notes) || !Array.isArray(response.conflicts)
      || !response.notes.every(isNote)
      || new Set(response.notes.map(note => note.id.toLowerCase())).size !== response.notes.length
      || !response.conflicts.every(item => item && isNote(item.note) && item.id === item.note.id)
      || !(response.deskPalId === null || typeof response.deskPalId === 'string' && uuid.test(response.deskPalId))) throw new Error('Invalid notes response.');
  const notes = Object.fromEntries(response.notes.map(note => [note.id, copy(note)]));
  const conflicts = Object.fromEntries(response.conflicts.map(item => [item.id, item]));
  state.notes = notes;
  state.deskPalId = response.deskPalId;
  for (const id of Object.keys(state.conflicts)) if (notes[id]) state.conflicts[id] = { note: copy(notes[id]) };
  for (const snapshot of sent) {
    const id = snapshot.note.id;
    const pending = state.pending[id];
    if (!pending) continue;
    if (conflicts[id]) { state.conflicts[id] = { note: copy(conflicts[id].note) }; continue; }
    const accepted = notes[id];
    if (!accepted) continue;
    delete state.conflicts[id];
    if (pending.revision === snapshot.revision) delete state.pending[id];
    else {
      const desired = copy(accepted);
      for (const field of fields) if (pending.note[field] !== snapshot.note[field]) desired[field] = pending.note[field];
      if (pending.note.body !== snapshot.note.body) {
        const body = mergeNoteBody(snapshot.note.body, accepted.body, pending.note.body);
        if (body === null || body.length > 65_536) {
          state.conflicts[id] = { note: copy(accepted) };
          continue;
        }
        desired.body = body;
      }
      if (fields.every(field => desired[field] === accepted[field])) delete state.pending[id];
      else state.pending[id] = { note: desired, base: copy(accepted), revision: pending.revision };
    }
  }
  return state;
}

/** An own acknowledgement must advance a focused editor without losing its caret. */
export function editorAfterAcknowledgement(state, sent, editor) {
  if (!editor || !sent.some(entry => entry.note.id === editor.id) || state.conflicts[editor.id]) return null;
  const note = state.pending[editor.id]?.note || state.notes[editor.id];
  const base = state.pending[editor.id]?.base || state.notes[editor.id];
  if (!note || !base || !['title', 'body'].includes(editor.field)) return null;
  const before = editor.value, after = note[editor.field];
  let prefix = 0;
  while (prefix < before.length && prefix < after.length && before[prefix] === after[prefix]) prefix++;
  let oldEnd = before.length, newEnd = after.length;
  while (oldEnd > prefix && newEnd > prefix && before[oldEnd - 1] === after[newEnd - 1]) { oldEnd--; newEnd--; }
  const position = value => Math.max(0, Math.min(after.length, value <= prefix ? value : value >= oldEnd ? value + newEnd - oldEnd : prefix + Math.min(value - prefix, newEnd - prefix)));
  return { note: copy(note), base: copy(base), start: position(editor.start), end: position(editor.end) };
}

export function resolveNoteConflict(state, id, choice, recoveredId) {
  const pending = state.pending[id];
  const conflict = state.conflicts[id];
  if (!pending || !conflict) return;
  if (choice === 'server') delete state.pending[id];
  else if (choice === 'local') {
    const desired = copy(conflict.note);
    for (const field of fields) if (!pending.base || pending.note[field] !== pending.base[field]) desired[field] = pending.note[field];
    if (conflict.note.deleted && !pending.note.deleted) {
      if (!uuid.test(recoveredId) || recoveredId.toLowerCase() === id.toLowerCase()) throw new Error('A new note ID is required to recover a deleted note.');
      desired.id = recoveredId; desired.deleted = false; desired.version = 0; desired.taskIds = [];
      state.pending[recoveredId] = { note: desired, base: null, revision: state.nextRevision++ };
      delete state.pending[id];
    } else state.pending[id] = { note: desired, base: copy(conflict.note), revision: state.nextRevision++ };
  } else throw new Error('Invalid conflict choice.');
  delete state.conflicts[id];
}
import { mergeNoteBody } from './note-text.mjs';
