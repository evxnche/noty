import { emptyState, restoreState, enqueue, visibleTasks, prepareChanges, applyResponse, resolveConflict } from './queue.mjs';
import { emptyNoteState, restoreNoteState, enqueueNote, visibleNotes, prepareNoteChanges, applyNoteResponse, resolveNoteConflict, editorAfterAcknowledgement } from './notes-queue.mjs';

const SESSION_KEY = 'noty-sync-session-v1';
const el = id => document.getElementById(id);
let token = '';
let state = emptyState();
let noteState = emptyNoteState();
let lastSync = null;
let checkedThisSession = false;
let storageError = false;
let requestError = '';
let busy = false;
let rerun = false;
let epoch = 0;
let controller;
let timer;
let selectedList = 'all';
let filter = 'all';
let editingId = null;
let draftList = null;
let view = 'tasks';
let selectedNote = null;
let renderedNote = null;
let editorBase = null;

// A fragment never reaches the server; remove it before rendering or requesting data.
const pairingToken = new URLSearchParams(location.hash.slice(1)).get('token');
if (location.hash) history.replaceState(null, '', location.pathname + location.search);

try {
  const saved = JSON.parse(localStorage.getItem(SESSION_KEY) || 'null');
  if (saved && validToken(saved.token)) {
    token = saved.token;
    state = restoreState(saved.state);
    noteState = restoreNoteState(saved.noteState);
    lastSync = Number.isFinite(saved.lastSync) ? saved.lastSync : null;
  }
} catch {
  storageError = true;
}

function validToken(value) {
  return typeof value === 'string' && value.length >= 32 && !/[\r\n]/.test(value);
}

function notice(message = '') {
  el('notice').textContent = message;
  el('notice').hidden = !message;
}

function persist(next, nextToken = token, syncedAt = lastSync, nextNotes = noteState) {
  try {
    localStorage.setItem(SESSION_KEY, JSON.stringify({ token: nextToken, state: next, noteState: nextNotes, lastSync: syncedAt }));
    storageError = false;
    state = next;
    noteState = nextNotes;
    token = nextToken;
    lastSync = syncedAt;
    return true;
  } catch {
    storageError = true;
    notice('This browser cannot save changes. Free some browser storage or allow site storage, then retry.');
    render();
    return false;
  }
}

function connect(key) {
  const nextToken = key.trim();
  if (!validToken(nextToken)) {
    notice('Use the private sync key from Noty. It has at least 32 characters.');
    return;
  }
  if (token && token !== nextToken && pendingCount()) {
    // Keep the existing offline edits until the user explicitly clears this device.
    notice('This browser has unsynced edits for another key. Sync them first, or disconnect and clear this device before connecting again.');
    return;
  }
  const next = token === nextToken ? state : emptyState();
  const nextNotes = token === nextToken ? noteState : emptyNoteState();
  if (!persist(next, nextToken, token === nextToken ? lastSync : null, nextNotes)) return;
  epoch++;
  controller?.abort();
  busy = false;
  checkedThisSession = false;
  requestError = '';
  el('token').value = '';
  notice();
  render();
  schedule(0);
}

function mutate(task) {
  const next = structuredClone(state);
  enqueue(next, task);
  let nextNotes = noteState;
  const existingList = Object.values(state.tasks).some(item => item.noteId.toLowerCase() === task.noteId.toLowerCase());
  if (!currentNote(task.noteId) && !existingList && !task.deleted) {
    nextNotes = structuredClone(noteState);
    enqueueNote(nextNotes, { id: task.noteId, title: task.listTitle, body: '', archived: false, deleted: false, version: 0, taskIds: [] });
  }
  if (!persist(next, token, lastSync, nextNotes)) return false;
  notice();
  render();
  schedule();
  return true;
}

function mutateNote(note, base) {
  const next = structuredClone(noteState);
  try { enqueueNote(next, note, base); }
  catch { notice('This note is too long to sync. Keep its text and shorten it before retrying.'); return false; }
  if (!persist(state, token, lastSync, next)) return false;
  notice();
  renderStatus();
  renderNoteConflicts();
  el('note-save-status').textContent = 'Saved on this phone · waiting to sync';
  schedule();
  return true;
}

function pendingCount() { return Object.keys(state.pending).length + Object.keys(noteState.pending).length; }

function schedule(delay = 650) {
  clearTimeout(timer);
  timer = setTimeout(sync, delay);
}

async function sync() {
  if (!token || document.hidden || !navigator.onLine) {
    renderStatus();
    return;
  }
  if (busy) {
    rerun = true;
    return;
  }
  const requestEpoch = epoch;
  const requestToken = token;
  // Fifty maximum-sized UTF-16 tasks and their bases fit the API body limit.
  const sent = prepareChanges(state).slice(0, 50);
  let sentNotes = prepareNoteChanges(noteState);
  busy = true;
  rerun = false;
  requestError = '';
  controller = new AbortController();
  const requestController = controller;
  const timeout = setTimeout(() => requestController.abort(), 15000);
  renderStatus();
  try {
    // A new task list must exist as a full note before its legacy task insertion.
    // Existing unpublished Mac notes are never synthesized from task-only records.
    const creations = sentNotes.filter(entry => entry.base === null);
    if (creations.length) {
      const creationResponse = await fetch('/api/notes', {
        method: 'POST', headers: { Authorization: `Bearer ${requestToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ changes: creations.map(({ note, base }) => ({ note, base })) }),
        cache: 'no-store', credentials: 'omit', signal: requestController.signal,
      });
      if (!creationResponse.ok) throw new Error(`Notes sync unavailable (${creationResponse.status}). Your edits are kept here.`);
      const createdBody = await creationResponse.json();
      if (requestEpoch !== epoch || requestToken !== token) return;
      if (!persist(state, token, lastSync, applyNoteResponse(structuredClone(noteState), createdBody, creations))) return;
      refreshAcknowledgedEditor(creations);
      sentNotes = sentNotes.filter(entry => !creations.includes(entry));
    }
    const response = await fetch('/api/sync', {
      method: sent.length ? 'POST' : 'GET',
      headers: {
        Authorization: `Bearer ${requestToken}`,
        ...(sent.length ? { 'Content-Type': 'application/json' } : {}),
      },
      ...(sent.length ? { body: JSON.stringify({ changes: sent.map(({ task, base }) => ({ task, base })) }) } : {}),
      cache: 'no-store',
      credentials: 'omit',
      signal: requestController.signal,
    });
    if (!response.ok) {
      throw new Error(response.status === 401 ? 'Key not accepted. Open a fresh phone link from Noty.' : `Sync unavailable (${response.status}). Your edits are kept here.`);
    }
    const body = await response.json();
    if (requestEpoch !== epoch || requestToken !== token) return;
    const next = applyResponse(structuredClone(state), body, sent);
    const acknowledged = sent.some(entry => !next.pending[entry.task.id]
      || next.pending[entry.task.id].base?.version !== entry.base?.version);
    if (!persist(next)) return;
    if (acknowledged && prepareChanges(next).length) rerun = true;
    const notesResponse = await fetch('/api/notes', {
      method: sentNotes.length ? 'POST' : 'GET',
      headers: { Authorization: `Bearer ${requestToken}`, ...(sentNotes.length ? { 'Content-Type': 'application/json' } : {}) },
      ...(sentNotes.length ? { body: JSON.stringify({ changes: sentNotes.map(({ note, base }) => ({ note, base })) }) } : {}),
      cache: 'no-store', credentials: 'omit', signal: requestController.signal,
    });
    if (!notesResponse.ok) throw new Error(notesResponse.status === 401 ? 'Key not accepted. Open a fresh phone link from Noty.' : `Notes sync unavailable (${notesResponse.status}). Your edits are kept here.`);
    const notesBody = await notesResponse.json();
    if (requestEpoch !== epoch || requestToken !== token) return;
    const nextNotes = applyNoteResponse(structuredClone(noteState), notesBody, sentNotes);
    const noteAcknowledged = sentNotes.some(entry => !nextNotes.pending[entry.note.id] || nextNotes.pending[entry.note.id].base?.version !== entry.base?.version);
    if (!persist(state, token, Date.now(), nextNotes)) return;
    refreshAcknowledgedEditor(sentNotes);
    checkedThisSession = true;
    // Refresh task rows after a full-text edit; their server-maintained IDs may change.
    if (noteAcknowledged || sentNotes.length < prepareNoteChanges(noteState).length) rerun = true;
    render();
  } catch (error) {
    if (requestEpoch !== epoch) return;
    requestError = error.name === 'AbortError' ? 'Sync timed out. Your edits are kept here.'
      : error instanceof TypeError ? 'Cannot reach sync. Your edits are kept here.'
      : ['Invalid sync response.', 'Invalid notes response.'].includes(error.message) ? 'Sync response was not recognized. Your edits are kept here.'
      : error.message;
  } finally {
    clearTimeout(timeout);
    if (requestEpoch === epoch) {
      busy = false;
      renderStatus();
      if (rerun && !requestError && !storageError) schedule(0);
    }
  }
}

function allLists() {
  const lists = new Map();
  for (const note of visibleNotes(noteState)) if (!note.archived) lists.set(note.id, note.title || 'Tasks');
  for (const task of visibleTasks(state)) {
    if (!lists.has(task.noteId)) lists.set(task.noteId, task.listTitle || 'Tasks');
  }
  if (draftList) lists.set(draftList.noteId, draftList.title);
  return lists;
}

function currentTask(id) {
  return state.pending[id]?.task || state.tasks[id];
}

function renderStatus() {
  const count = pendingCount();
  const conflicts = Object.keys(state.conflicts).length + Object.keys(noteState.conflicts).length;
  let message = 'Not connected';
  let mode = 'idle';
  if (storageError) message = 'Browser storage unavailable';
  else if (token) {
    if (!navigator.onLine) message = count ? `Offline · ${count} ${count === 1 ? 'change' : 'changes'} saved here` : 'Offline · showing saved notes and tasks';
    else if (busy) { message = count ? `Syncing · ${count} ${count === 1 ? 'change' : 'changes'} waiting` : 'Checking for updates…'; mode = 'syncing'; }
    else if (requestError) message = requestError;
    else if (conflicts) message = `${conflicts} ${conflicts === 1 ? 'edit needs' : 'edits need'} your choice`;
    else if (count) message = `${count} ${count === 1 ? 'change' : 'changes'} waiting to sync`;
    else if (checkedThisSession) { message = 'Up to date'; mode = 'synced'; }
    else message = 'Connecting to your notes and tasks…';
  }
  el('status').textContent = message;
  el('status').parentElement.dataset.state = mode;
  el('retry-button').hidden = !token || busy || (!requestError && !storageError);
  el('pending-count').textContent = count ? `${count} pending` : '';
  el('last-sync').textContent = lastSync ? `Checked ${new Date(lastSync).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}` : '';
}

function currentNote(id) { return noteState.pending[id]?.note || noteState.notes[id]; }

function refreshAcknowledgedEditor(sent) {
  const focused = document.activeElement;
  const field = focused === el('note-body') ? 'body' : focused === el('note-title') ? 'title' : null;
  if (!field) return;
  const next = editorAfterAcknowledgement(noteState, sent, { id: selectedNote, field, value: focused.value, start: focused.selectionStart, end: focused.selectionEnd });
  if (!next) return;
  const scroll = focused.scrollTop;
  if (focused.value !== next.note[field]) {
    focused.value = next.note[field];
    focused.setSelectionRange(next.start, next.end);
    focused.scrollTop = scroll;
  }
  editorBase = next.base;
  renderedNote = next.note;
}

function renderNotes() {
  const notes = visibleNotes(noteState);
  if (!notes.some(note => note.id === selectedNote)) selectedNote = notes.find(note => note.id === noteState.deskPalId)?.id || notes[0]?.id || null;
  const select = el('note-select');
  select.replaceChildren();
  for (const note of notes) select.add(new Option(`${note.title || 'Untitled'}${note.archived ? ' (archived)' : ''}`, note.id));
  if (selectedNote) select.value = selectedNote;
  select.disabled = storageError || !notes.length;
  const note = currentNote(selectedNote);
  el('note-empty').hidden = !!note;
  el('note-editor').hidden = !note;
  if (!note) { renderedNote = null; return; }
  const changedNote = renderedNote?.id !== note.id;
  if (changedNote || document.activeElement !== el('note-title')) el('note-title').value = note.title;
  if (changedNote || document.activeElement !== el('note-body')) el('note-body').value = note.body;
  if (changedNote || !['note-title', 'note-body'].includes(document.activeElement?.id)) renderedNote = structuredClone(note);
  el('note-title').disabled = storageError;
  el('note-body').disabled = storageError;
  el('note-save-button').disabled = storageError;
  el('note-save-status').textContent = noteState.conflicts[note.id] ? 'Two versions kept · choose below'
    : noteState.pending[note.id] ? 'Saved on this phone · waiting to sync' : 'All changes saved';
}

function renderNoteConflicts() {
  const container = el('note-conflicts');
  container.replaceChildren();
  for (const [id, conflict] of Object.entries(noteState.conflicts)) {
    const pending = noteState.pending[id];
    if (!pending) continue;
    const card = node('div', 'conflict');
    for (const [label, note] of [['This phone', pending.note], ['Other screen', conflict.note]]) {
      const paragraph = node('div');
      paragraph.append(node('span', 'conflict-label', `${label} · ${note.title || 'Untitled'}`), node('pre', 'note-conflict-text', note.deleted ? 'Note deleted' : note.body));
      card.append(paragraph);
    }
    const actions = node('div', 'conflict-actions');
    for (const [choice, label] of [['server', 'Use other screen'], ['local', 'Keep my edit']]) {
      const button = node('button', '', label);
      button.type = 'button'; button.disabled = storageError;
      button.addEventListener('click', () => {
        const next = structuredClone(noteState);
        resolveNoteConflict(next, id, choice, crypto.randomUUID());
        if (persist(state, token, lastSync, next)) { renderedNote = null; render(); schedule(0); }
      });
      actions.append(button);
    }
    card.append(actions); container.append(card);
  }
  el('note-conflict-section').hidden = !container.childElementCount;
}

function node(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}

function renderConflicts() {
  const container = el('conflicts');
  container.replaceChildren();
  for (const [id, conflict] of Object.entries(state.conflicts)) {
    const pending = state.pending[id];
    if (!pending) continue;
    const card = node('div', 'conflict');
    for (const [label, task] of [['This phone', pending.task], ['Other screen', conflict.task]]) {
      const paragraph = node('p');
      paragraph.append(node('span', 'conflict-label', label), document.createTextNode(task.deleted ? 'Task deleted' : task.text));
      card.append(paragraph);
    }
    const actions = node('div', 'conflict-actions');
    for (const [choice, label] of [['server', 'Use other screen'], ['local', 'Keep my edit']]) {
      const button = node('button', '', label);
      button.type = 'button';
      button.disabled = storageError;
      button.addEventListener('click', () => {
        const next = structuredClone(state);
        resolveConflict(next, id, choice, crypto.randomUUID());
        if (persist(next)) { render(); schedule(0); }
      });
      actions.append(button);
    }
    card.append(actions);
    container.append(card);
  }
  el('conflict-section').hidden = !container.childElementCount;
}

function renderTasks() {
  const lists = allLists();
  if (selectedList !== 'all' && !lists.has(selectedList)) selectedList = 'all';
  const select = el('list-select');
  select.replaceChildren(new Option('All lists', 'all'));
  for (const [id, title] of lists) select.add(new Option(title, id));
  select.value = selectedList;
  select.disabled = storageError;
  el('list-title').textContent = selectedList === 'all' ? 'Tasks' : lists.get(selectedList);
  const tasks = visibleTasks(state).filter(task => selectedList === 'all' || task.noteId === selectedList);
  const done = tasks.filter(task => task.completed).length;
  el('task-count').textContent = `${tasks.length - done} open\n${done} done`;
  const shown = tasks.filter(task => filter === 'all' || task.completed === (filter === 'done'));
  const container = el('task-list');
  const focused = document.activeElement;
  const focusedId = focused?.dataset?.taskId;
  const focusedAction = focused?.dataset?.action;
  container.replaceChildren();
  for (const task of shown) {
    const row = node('li', `task-row${task.completed ? ' completed' : ''}`);
    const check = node('button', 'task-check');
    check.type = 'button';
    check.setAttribute('role', 'checkbox');
    check.setAttribute('aria-checked', String(task.completed));
    check.setAttribute('aria-label', `${task.completed ? 'Mark open' : 'Complete'}: ${task.text}`);
    check.dataset.taskId = task.id;
    check.dataset.action = 'toggle';
    check.disabled = storageError;
    const box = node('span', 'check-box', task.completed ? '✓' : '');
    box.setAttribute('aria-hidden', 'true');
    check.append(box);
    check.addEventListener('click', () => { const current = currentTask(task.id); mutate({ ...current, completed: !current.completed }); });
    const content = node('div', 'task-content');
    const text = node('button', 'task-text', task.text);
    text.type = 'button';
    text.dataset.taskId = task.id;
    text.dataset.action = 'edit';
    text.setAttribute('aria-label', `Edit: ${task.text}`);
    text.disabled = storageError;
    text.addEventListener('click', () => {
      editingId = task.id;
      el('edit-text').value = currentTask(task.id).text;
      el('edit-dialog').showModal();
      el('edit-text').focus();
    });
    content.append(text);
    if (selectedList === 'all') content.append(node('span', 'task-list-label', task.listTitle || 'Tasks'));
    const remove = node('button', 'task-delete', '×');
    remove.type = 'button';
    remove.dataset.taskId = task.id;
    remove.dataset.action = 'delete';
    remove.disabled = storageError;
    remove.setAttribute('aria-label', `Delete: ${task.text}`);
    remove.addEventListener('click', () => mutate({ ...currentTask(task.id), deleted: true }));
    row.append(check, content, remove);
    container.append(row);
  }
  if (focusedId && focusedAction) {
    // Keep keyboard focus stable during polls without inserting user text into selectors.
    [...container.querySelectorAll('button')].find(button => button.dataset.taskId === focusedId && button.dataset.action === focusedAction)?.focus({ preventScroll: true });
  }
  el('empty-list').hidden = !!shown.length;
  el('empty-description').textContent = filter === 'done' ? 'Completed tasks will appear here.'
    : filter === 'open' && tasks.length ? 'Everything in this list is done.' : 'Add the first task above.';
}

function render() {
  el('connect-section').hidden = !!token;
  el('view-switch').hidden = !token;
  el('tasks-section').hidden = !token || view !== 'tasks';
  el('notes-section').hidden = !token || view !== 'notes';
  for (const button of document.querySelectorAll('[data-view]')) button.setAttribute('aria-pressed', String(button.dataset.view === view));
  el('disconnect-button').hidden = !token;
  el('new-task').disabled = !token || storageError;
  el('add-form').querySelector('button').disabled = !token || storageError;
  el('new-list-button').disabled = !token || storageError;
  renderStatus();
  renderTasks();
  renderConflicts();
  renderNotes();
  renderNoteConflicts();
}

el('connect-form').addEventListener('submit', event => { event.preventDefault(); connect(el('token').value); });
el('retry-button').addEventListener('click', () => schedule(0));
el('add-form').addEventListener('submit', event => {
  event.preventDefault();
  const text = el('new-task').value.trim();
  if (!text || /[\r\n]/.test(text)) return;
  const tasks = visibleTasks(state);
  const lists = allLists();
  const defaultTask = tasks.find(task => !task.listTitle || task.listTitle === 'Tasks');
  const noteId = selectedList !== 'all' ? selectedList : noteState.deskPalId || defaultTask?.noteId || crypto.randomUUID();
  const listTitle = lists.get(noteId) || 'Tasks';
  const positions = tasks.filter(task => task.noteId === noteId).map(task => task.position);
  const position = positions.length ? positions.reduce((maximum, value) => Math.max(maximum, value), -Infinity) + 1 : 0;
  if (mutate({ id: crypto.randomUUID(), noteId, listTitle, text, completed: false, position, deleted: false, version: 0 })) {
    el('new-task').value = '';
    el('new-task').focus();
  }
});
el('edit-form').addEventListener('submit', event => {
  event.preventDefault();
  const text = el('edit-text').value.trim();
  const task = currentTask(editingId);
  if (!task || !text || /[\r\n]/.test(text)) return;
  if (mutate({ ...task, text })) el('edit-dialog').close();
});
el('list-select').addEventListener('change', event => { selectedList = event.target.value; renderTasks(); });
el('new-list-button').addEventListener('click', () => { el('list-name').value = ''; el('list-dialog').showModal(); el('list-name').focus(); });
el('list-form').addEventListener('submit', event => {
  event.preventDefault();
  const title = el('list-name').value.trim();
  if (!title || /[\r\n]/.test(title)) return;
  draftList = { noteId: crypto.randomUUID(), title };
  selectedList = draftList.noteId;
  el('list-dialog').close();
  renderTasks();
  el('new-task').focus();
});
for (const button of document.querySelectorAll('[data-filter]')) {
  button.addEventListener('click', () => {
    filter = button.dataset.filter;
    for (const other of document.querySelectorAll('[data-filter]')) other.setAttribute('aria-pressed', String(other === button));
    renderTasks();
  });
}
for (const button of document.querySelectorAll('[data-view]')) button.addEventListener('click', () => { view = button.dataset.view; render(); });
el('note-select').addEventListener('change', event => { selectedNote = event.target.value; renderedNote = null; editorBase = null; renderNotes(); });
for (const [id, field] of [['note-title', 'title'], ['note-body', 'body']]) {
  el(id).addEventListener('focus', () => { editorBase = structuredClone(renderedNote || currentNote(selectedNote)); });
  el(id).addEventListener('input', () => {
    const note = currentNote(selectedNote);
    if (note) mutateNote({ ...note, [field]: el(id).value }, editorBase);
  });
  el(id).addEventListener('blur', () => { editorBase = null; renderNotes(); });
}
el('note-editor').addEventListener('submit', event => { event.preventDefault(); schedule(0); });
for (const button of document.querySelectorAll('[data-close]')) button.addEventListener('click', () => el(button.dataset.close).close());
el('disconnect-button').addEventListener('click', () => {
  const count = pendingCount();
  el('disconnect-description').textContent = count
    ? `${count} unsynced ${count === 1 ? 'change' : 'changes'} and saved notes and tasks will be removed from this browser. Your other screens keep their data.`
    : 'Saved notes, tasks and the private key will be removed from this browser. Your other screens keep their data.';
  el('disconnect-dialog').showModal();
});
el('confirm-disconnect').addEventListener('click', () => {
  try { localStorage.removeItem(SESSION_KEY); } catch { notice('This browser could not clear its saved key. Clear site data in your browser settings.'); return; }
  epoch++;
  controller?.abort();
  clearTimeout(timer);
  token = '';
  state = emptyState();
  noteState = emptyNoteState();
  lastSync = null;
  checkedThisSession = false;
  storageError = false;
  requestError = '';
  busy = false;
  draftList = null;
  selectedList = 'all';
  selectedNote = null;
  renderedNote = null;
  editorBase = null;
  el('disconnect-dialog').close();
  render();
  notice();
});
window.addEventListener('online', () => { renderStatus(); schedule(0); });
window.addEventListener('offline', renderStatus);
document.addEventListener('visibilitychange', () => { if (!document.hidden) schedule(0); });
setInterval(() => { if (!document.hidden && navigator.onLine) sync(); }, 15000);

render();
if (storageError) notice('Saved browser data could not be read. Allow site storage before connecting.');
if (pairingToken !== null) connect(pairingToken);
else if (token) schedule(0);
if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {
  notice('Offline reopening is unavailable in this browser. Keep this page open to use saved tasks offline.');
});
