function rangeEdit(base, changed) {
  let start = 0;
  while (start < base.length && start < changed.length && base[start] === changed[start]) start++;
  let end = base.length, changedEnd = changed.length;
  while (end > start && changedEnd > start && base[end - 1] === changed[changedEnd - 1]) { end--; changedEnd--; }
  return { start, end, lines: changed.slice(start, changedEnd) };
}

/** Disjoint line edits merge; ambiguous/overlapping replacements stay a conflict. */
export function mergeNoteBody(baseBody, currentBody, desiredBody) {
  if (currentBody === baseBody || currentBody === desiredBody) return desiredBody;
  if (desiredBody === baseBody) return currentBody;
  const lines = baseBody.split('\n');
  const a = rangeEdit(lines, currentBody.split('\n'));
  const b = rangeEdit(lines, desiredBody.split('\n'));
  if (a.start === b.start && (a.start === a.end || b.start === b.end)) return null;
  if (!(a.end <= b.start || b.end <= a.start)) return null;
  for (const edit of [a, b].sort((a, b) => b.start - a.start)) lines.splice(edit.start, edit.end - edit.start, ...edit.lines);
  return lines.join('\n');
}
