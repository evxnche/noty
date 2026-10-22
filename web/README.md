# Noty shared notes and tasks

A private mobile note/task page and sync APIs for the native Noty app. No runtime
dependencies; Node.js 22 or newer. Vercel serves `public/`, `api/sync.mjs` and
`api/notes.mjs`.

## Deploy your own

Each person runs their own copy: their own Vercel project, Redis store and key.
Nothing here points at anyone else's server. Needs a free Vercel account and the
Vercel CLI (`npm i -g vercel`, or prefix commands with `npx`).

1. Make the sync key (64 hex characters; the app and server need 32+, no spaces):

   ```sh
   openssl rand -hex 32
   ```

   Keep it in a password manager. It is the only credential clients ever hold.

2. Create the Vercel project from this folder. No build command; Vercel reads
   `vercel.json` (output `public`, functions `api/sync.mjs` and `api/notes.mjs`,
   Node 24):

   ```sh
   cd web
   vercel link        # answer "no" to linking an existing project; pick a new name
   ```

3. Add durable storage: Vercel dashboard → your project → **Storage** → **Upstash
   for Redis** (Marketplace) → free plan, automatic upgrades off, **eviction off**
   (deletion markers must never be evicted) → connect it to the project for all
   environments. Vercel may ask you to accept Upstash's marketplace terms first.
   This injects `KV_REST_API_URL` and `KV_REST_API_TOKEN` (some setups also add
   `UPSTASH_REDIS_REST_URL`/`_TOKEN`; either pair works).

4. Add the key:

   ```sh
   vercel env add NOTY_SYNC_TOKEN production   # paste the key from step 1
   ```

5. Deploy, then check it (expect `200` and JSON with `"notes"`):

   ```sh
   vercel --prod
   curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $KEY" https://YOUR-PROJECT.vercel.app/api/notes
   ```

   A `503` means the key or the Redis variables are missing; redeploy after
   adding them. A `401` means the key in the request doesn't match.

### Environment variables

| Variable | Where | Purpose |
|---|---|---|
| `NOTY_SYNC_TOKEN` | Vercel + local | Shared bearer key, 32+ chars. Required; the API answers 503 without it. |
| `KV_REST_API_URL` / `KV_REST_API_TOKEN` | Vercel (set by Upstash integration) | Upstash Redis REST endpoint and token. |
| `UPSTASH_REDIS_REST_URL` / `UPSTASH_REDIS_REST_TOKEN` | Vercel (alternative) | Same, under Upstash's own names. If either is set, both must be, and they win over `KV_*`. |
| `NOTY_SYNC_REDIS_KEY` | optional | Redis key for the snapshot. Default `noty:tasks:v1`. |
| `NOTY_SYNC_FILE` | local `npm start` only | JSON file store when no Redis variables are set. Default `web/.data/tasks.json`. |
| `NOTY_SYNC_HOST` / `PORT` | local `npm start` only | Bind address (default `127.0.0.1`) and port (default `8787`). |

Redis credentials stay in Vercel. Never put them in the app, the phone or the board.

### Point the Noty Mac app at it

Right-click the Noty pill → **Task Sync…** →
**Sync site** `https://YOUR-PROJECT.vercel.app` (the root address only: no
path, query or trailing `/api`), **Private key** = the key from step 1 → tick
**Sync notes and tasks** → **Save settings**. The QR code under "Connect your
phone" pairs the phone page. The settings are stored encrypted in
`~/Library/Application Support/Noty/task-sync-config.enc`, not in this repo.

### Point the desk-voice server at it

The desk-voice (Ray-Ban Meta / Desk Pal) server reads and writes notes through
`/api/notes`. Set these on that server (its own Vercel env or `.env`), not here:

```sh
NOTY_NOTES_URL=https://YOUR-PROJECT.vercel.app/api/notes
NOTY_SYNC_TOKEN=<the same key from step 1>
```

`NOTY_NOTES_URL` is the full `/api/notes` address. Without it, desk-voice
falls back to its built-in default URL, which is someone else's server, so
always set it.

## Local verification

```sh
cd web
NOTY_SYNC_TOKEN=noty-local-verification-key-20261004 \
NOTY_SYNC_FILE=/private/tmp/noty-local-tasks.json npm start
```

Open `http://127.0.0.1:8787`, enter that test key, and add a synthetic task.
The local server listens on loopback by default. `NOTY_SYNC_HOST=0.0.0.0` enables
LAN testing; HTTP is for disposable local tests, not private cloud use.
The native app accepts HTTP only on loopback; hosted endpoints require HTTPS.
The file adapter is for a single local server process, not Vercel storage.

```sh
npm test
npm run check
node --test mobile-test/*.test.mjs
```

From the repository root, `./scripts/run-sync-integration.sh` tests the actual
Swift engine against this service. Its database and key use a disposable
`NOTY_SUPPORT_DIR`, so it does not touch your real notes.

## Private cloud setup

1. Deploy `web/` as a separate Vercel project (no build command; output `public`).
2. Add `NOTY_SYNC_TOKEN`, a randomly generated key with at least 32 characters.
3. Connect a durable Upstash Redis store. Choose the free plan and disable
   automatic upgrades when provisioning; keep eviction disabled so deletion
   markers cannot disappear. Vercel may require the account owner to accept
   Upstash marketplace terms first.
4. Set `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`, or the paired
   `KV_REST_API_URL` and `KV_REST_API_TOKEN` marketplace variables, then redeploy.
5. In Noty → Task Sync, save the site's HTTPS root address and private key,
   enable sync, and scan the QR code with your phone.

Production fails closed with HTTP 503 if the private key or durable storage is
absent. Do not put Redis credentials in the browser, native app or ESP32. Only
the task API key is shared with clients. Changing that key and redeploying revokes
existing phone links; update your native settings too. No keys belong in Git.

The mobile pairing link stores the key in its fragment, then clears the fragment
immediately. Browser storage holds the key, note/task cache and pending edits on
that device. Disconnect clears them. The Notes view edits complete titles and
bodies; the selector defaults to Desk Pal when a role is configured. Edits save
locally on each input, retaining the original server document until acknowledged.
Edits typed during a request are retained and rebased, and overlapping text keeps
both versions for an explicit choice. The service worker caches only app-shell
assets, never API responses or credentials. Full note text is private cloud data,
not end-to-end encrypted; safeguard the key. Photo files remain local to the Mac.

## Full-note API

Both endpoints require the same `Authorization: Bearer <private key>` header.
`GET /api/notes` returns `{notes, conflicts: [], deskPalId}` including archived
documents and deletion markers. `deskPalId` is the UUID of the selected board
note or null. Each document contains exactly:

```json
{"id":"UUID","title":"Desk Pal","body":"# to-do\n☐ Buy milk\n# idea\nLamp","archived":false,"deleted":false,"version":1,"taskIds":["TASK_UUID"]}
```

Title may be empty and is limited to 120 UTF-16 units without control characters.
Body is limited to 65,536 UTF-16 units, without truncation. `taskIds` is maintained
by the server and aligns with extracted task rows in body order. Clients may send
their last observed mapping or an empty array for first publication; a supplied
mapping cannot claim another task's identity. UUID comparisons are case-insensitive.

`POST /api/notes` accepts `{changes:[{note,base}],deskPalId?}` with up to 256
changes and a maximum 1 MiB UTF-8 JSON body. `base` is null for first publication,
otherwise the entire previously observed server document. The server stores up
to 256 documents including tombstones, rejects excess capacity and never evicts
existing text. Versions are server-assigned. Identical retries do not bump them.
Deleting sets `deleted:true`; a deleted identity cannot be resurrected.

Title/body/archive/delete fields merge independently. Disjoint line ranges in
body can merge; overlapping edits return `conflicts:[{id,note}]` and apply none
of that document's edits. Keep both local and remote full texts and their base
until the user explicitly chooses a version. A recovery of a deleted note uses
a new UUID. Mobile batches changes below the byte limit and keeps requests retryable.

For the selected Desk Pal note, task rows are nonempty plain lines, bullets,
native `☐/☑`, or Markdown checkboxes under first-level `# to-do`, `# todo` or
`# to do` (case-insensitive). A following heading ends the section; fenced code
is excluded. Other notes contribute only native or Markdown checkbox rows.
Project sections `# idea`, `# building`, `# testing`, and `# shipped` (`shift`
is a supported alias) remain full text for the board's project projection.

Both APIs use the same atomic snapshot. Full-note writes reconcile task records,
and legacy task edits rewrite the exact mapped note line while preserving other
text and headings. New task insertions use native `☐/☑` and go before the next
Desk Pal heading. Legacy list creation on the phone publishes its full document
before inserting tasks. Existing unpublished-note task records remain intact
until their original full documents are published; the service does not invent
or overwrite those original notes from task-only data.

## API for ESP32 integration

Desk Pal's `board/noty_sync.py` uses this HTTPS API with the private task key as a
bearer header. Existing board tasks are adopted into a separate Desk Pal list;
Noty notes keep their existing contents. The Plan screen projects only the
selected Desk Pal note, while all notes can provide assistant context. The board
retains original tasks during initial pairing and uses stable task identities
for future completion and deletion changes.

`GET /api/sync` returns `{ "tasks": [...], "conflicts": [] }` including tombstones.
Show records with `deleted == false`, grouped by `noteId`, ordered by `position`.
Poll at a bounded interval; do not cache deletion markers away.

Each task has `id`, `noteId` (UUID strings), `listTitle`, `text`, `completed`,
`position`, `deleted`, `version`. Text is a non-empty single line, at most 2,000
UTF-16 units; titles at most 120. IDs retain their originating casing; treat UUID
identities case-insensitively. Versions are assigned by the server.

`POST /api/sync`, with `Content-Type: application/json`, accepts up to 250 changes:

```json
{ "changes": [{ "task": { "id": "UUID", "noteId": "UUID", "listTitle": "Tasks", "text": "Buy milk", "completed": false, "position": 0, "deleted": false, "version": 0 }, "base": null }] }
```

For an existing task, `base` must contain the last server record you observed.
Change only the fields you edited in `task`; leave `base` unchanged until the
server acknowledges the write. Deletes set `deleted: true`. Responses always
contain the current `tasks` plus `conflicts: [{id, task}]`. Disjoint edits merge;
conflicts apply none of that task's fields. Preserve the local edit or ask which
version to retain. Restore a deleted task with a new UUID, not its old identity.

Redis uses an atomic EVAL compare-and-swap on `noty:tasks:v1`; the backward-compatible
snapshot now includes notes, selected Desk Pal ID and revision alongside tasks,
so concurrent function instances cannot overwrite each other's writes. See the official
[Upstash REST documentation](https://upstash.com/docs/redis/features/restapi)
and [Vercel Node function documentation](https://vercel.com/docs/functions/runtimes/node-js/advanced-node-configuration).
