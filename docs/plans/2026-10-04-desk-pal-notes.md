# Desk Pal sections and all-note voice context

User scope: only the Desk Pal note supplies the board Plan screen. Its five `#`
sections are to-do, idea, building, testing, and shipped (recognize shift as an
alias). Populate those sections from Mac or mobile. All other note text remains
available to the assistant for questions, and a named note appears on the board
only on an explicit display request. Preserve all existing task text/completion
and project names while moving their current representation into the headings.

## Shared contract

Extend the existing Redis snapshot atomically; preserve every existing task
record and legacy `/api/sync` behavior. The authoritative text source is a note
document `{id,title,body,archived,deleted,version,taskIds}`. `taskIds` is a
server-maintained array matching extracted task lines in body order. For the
selected Desk Pal note, extract nonempty items under # to-do (checkbox, bullet
or plain line); for other notes, extract existing checkbox lines. Other Desk Pal
sections represent projects and are not default to-do rows.

`GET /api/notes` returns `{notes,conflicts:[],deskPalId}`. `POST /api/notes`
accepts `{changes:[{note,base}], deskPalId?}`. Base is null for first publication,
otherwise the prior server document. Same-field divergent changes conflict;
disjoint fields merge. Body changes may merge disjoint line ranges; overlapping
changes preserve a conflict, never silently overwrite text. Responses contain
`conflicts:[{id,note}]`. Tombstones persist. The private bearer key and request
limits follow the existing service. Full note text is private cloud data, not
end-to-end encrypted; images remain local files.

Atomic bridge: note writes update legacy task records and stable identities in
the same compare-and-swap operation. Legacy task edits update the corresponding
note line, and task creation for Desk Pal inserts under # to-do before the next
header. Legacy tasks whose notes have not been published must stay intact. IDs
are matched against existing noteId/text/completion/order during first publication
so adding headings cannot delete/recreate existing tasks. Plain/bullet to-do
completion uses a checkbox when explicitly toggled.

## Ownership and execution

1. Native owner: switch the existing TaskSync controller to full-note transport,
   add an encrypted document ledger preserving drafts/in-flight changes and both
   versions on conflict, keep the old task ledger untouched, and create the five
   headings in the existing Desk Pal note while copying the existing eight
   board projects to the appropriate sections. Preserve all other note rows.
2. Service/mobile owner: extend atomic shared storage and implement notes API,
   two-way task/document bridge, mobile Notes selector and full-text editing with
   durable offline pending changes and conflict choices. Keep existing task UI.
3. Board owner: add document polling/cache, selected-note Plan projection, safe
   project section edits, and a paginated note viewer. Plan drawing/state/voice
   context and clear-done must use only Desk Pal; hidden cached tasks stay stored.
   GET/POST use the existing verified HTTPS transport and task credential.
4. Voice owner: fetch full-note context server-side using NOTY_NOTES_URL and
   NOTY_SYNC_TOKEN only after board authentication. Ground questions in note text
   as untrusted data. Add read/search tools and a gated show_note command with
   exact `note_id`; show-note is available only for explicit display intent.
   Ordinary note questions leave the board screen alone. Preserve all existing
   voice, wake, model, audio and Mac-control behavior.

## Verification

Back up current notes/key/ledgers and board state before migration, preserving
new user edits made since earlier backups. Test section parsing, shared legacy
identities, line merges, offline/retry/race preservation, display filtering,
project moves, prompt injection boundaries, named note display gating, and
preservation of unrelated notes. Verify mobile edits -> Mac -> board, original
task flags/project names, real board rendering, and the deployed voice context
path. Upload only changed application files; do not flash firmware or overwrite
credential/data files wholesale. Rebuild/install the native app with a backup.
