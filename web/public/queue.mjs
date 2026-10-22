const fields = ['noteId', 'listTitle', 'text', 'completed', 'position', 'deleted'];
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const copy = value => value === null ? null : { ...value };

export function isTask(task) {
  return task && typeof task === 'object' && uuid.test(task.id) && uuid.test(task.noteId)
    && typeof task.text === 'string' && task.text.trim().length > 0 && task.text.length <= 2000
    && typeof task.listTitle === 'string' && task.listTitle.length <= 120
    && !/[\r\n]/.test(task.text + task.listTitle)
    && typeof task.completed === 'boolean' && typeof task.deleted === 'boolean'
    && Number.isFinite(task.position) && Number.isSafeInteger(task.version) && task.version >= 0;
}

export function emptyState() {
  return { tasks: {}, pending: {}, conflicts: {}, nextRevision: 1 };
}

export function restoreState(saved) {
  const state = emptyState();
  if (!saved || typeof saved !== 'object') return state;
  for (const task of Object.values(saved.tasks || {})) {
    if (isTask(task)) state.tasks[task.id] = copy(task);
  }
  for (const entry of Object.values(saved.pending || {})) {
    if (!entry || !isTask(entry.task) || !(entry.base === null || isTask(entry.base))) continue;
    if (entry.base && entry.base.id !== entry.task.id) continue;
    state.pending[entry.task.id] = {
      task: copy(entry.task), base: copy(entry.base), revision: state.nextRevision++,
    };
  }
  for (const conflict of Object.values(saved.conflicts || {})) {
    if (conflict && isTask(conflict.task) && state.pending[conflict.task.id]) {
      state.conflicts[conflict.task.id] = { task: copy(conflict.task) };
    }
  }
  return state;
}

export function enqueue(state, task) {
  if (!isTask(task)) throw new Error('Invalid task.');
  const existing = state.pending[task.id];
  state.pending[task.id] = {
    task: copy(task), base: existing ? copy(existing.base) : copy(state.tasks[task.id] || null),
    revision: state.nextRevision++,
  };
}

export function visibleTasks(state) {
  const tasks = { ...state.tasks };
  for (const entry of Object.values(state.pending)) tasks[entry.task.id] = entry.task;
  return Object.values(tasks).filter(task => !task.deleted)
    .sort((a, b) => a.position - b.position || a.id.localeCompare(b.id));
}

export function prepareChanges(state) {
  return Object.values(state.pending).filter(entry => !state.conflicts[entry.task.id])
    .map(entry => ({ task: copy(entry.task), base: copy(entry.base), revision: entry.revision }));
}

export function applyResponse(state, response, sent = []) {
  if (!response || !Array.isArray(response.tasks) || !Array.isArray(response.conflicts)
      || !response.tasks.every(isTask)
      || !response.conflicts.every(item => item && isTask(item.task) && item.id === item.task.id)) {
    throw new Error('Invalid sync response.');
  }
  const tasks = Object.fromEntries(response.tasks.map(task => [task.id, copy(task)]));
  const conflicts = Object.fromEntries(response.conflicts.map(item => [item.id, item]));
  state.tasks = tasks;
  for (const id of Object.keys(state.conflicts)) {
    if (tasks[id]) state.conflicts[id] = { task: copy(tasks[id]) };
  }
  for (const snapshot of sent) {
    const id = snapshot.task.id;
    const pending = state.pending[id];
    if (!pending) continue;
    if (conflicts[id]) {
      state.conflicts[id] = { task: copy(conflicts[id].task) };
      continue;
    }
    const accepted = tasks[id];
    if (!accepted) continue;
    delete state.conflicts[id];
    if (pending.revision === snapshot.revision) {
      delete state.pending[id];
    } else {
      // Only changes made after this request started override the merged result.
      const desired = copy(accepted);
      for (const field of fields) {
        if (pending.task[field] !== snapshot.task[field]) desired[field] = pending.task[field];
      }
      if (fields.every(field => desired[field] === accepted[field])) delete state.pending[id];
      else state.pending[id] = { task: desired, base: copy(accepted), revision: pending.revision };
    }
  }
  return state;
}

export function resolveConflict(state, id, choice, recoveredId) {
  const pending = state.pending[id];
  const conflict = state.conflicts[id];
  if (!pending || !conflict) return;
  if (choice === 'server') {
    delete state.pending[id];
  } else if (choice === 'local') {
    const desired = copy(conflict.task);
    for (const field of fields) {
      if (!pending.base || pending.task[field] !== pending.base[field]) desired[field] = pending.task[field];
    }
    if (conflict.task.deleted && !pending.task.deleted) {
      if (!uuid.test(recoveredId) || recoveredId === id) throw new Error('A new task ID is required to keep a deleted task.');
      // A deliberate recovery creates a new task; the old tombstone is permanent.
      desired.id = recoveredId;
      desired.deleted = false;
      desired.version = 0;
      state.pending[recoveredId] = { task: desired, base: null, revision: state.nextRevision++ };
      delete state.pending[id];
    } else {
      state.pending[id] = { task: desired, base: copy(conflict.task), revision: state.nextRevision++ };
    }
  } else throw new Error('Invalid conflict choice.');
  delete state.conflicts[id];
}
