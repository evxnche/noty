import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const module = await import('../server.mjs').catch(() => ({}));

test('local server serves the mobile shell with a strict compatible CSP and private API', async t => {
  assert.equal(typeof module.createLocalServer, 'function', 'local server must be implemented');
  const directory = await mkdtemp(join(tmpdir(), 'noty-server-'));
  await writeFile(join(directory, 'index.html'), '<!doctype html><title>Noty</title>');
  await writeFile(join(directory, 'app.js'), 'console.log("Noty");');
  const server = module.createLocalServer({ publicDirectory: directory, token: 'private-development-token-32-characters', store: { async read() { return { revision: 0, tasks: [] }; } } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true }); });
  const url = `http://127.0.0.1:${server.address().port}`;
  const page = await fetch(url);
  assert.equal(page.status, 200);
  assert.equal(page.headers.get('content-type'), 'text/html; charset=utf-8');
  assert.match(page.headers.get('content-security-policy'), /script-src 'self'/);
  assert.equal(page.headers.get('referrer-policy'), 'no-referrer');
  assert.match(await page.text(), /Noty/);
  assert.equal((await fetch(`${url}/app.js`)).headers.get('content-type'), 'text/javascript; charset=utf-8');
  assert.equal((await fetch(`${url}/%2e%2e%2fpackage.json`)).status, 404);
  assert.equal((await fetch(`${url}/.env`)).status, 404);
  assert.equal((await fetch(`${url}/api/unknown`)).status, 404);
  assert.equal((await fetch(`${url}/api/sync`)).status, 401);
  const sync = await fetch(`${url}/api/sync`, { headers: { Authorization: 'Bearer private-development-token-32-characters' } });
  assert.deepEqual(await sync.json(), { tasks: [], conflicts: [] });
});
