import { createServer } from 'node:http';
import { readFile, realpath } from 'node:fs/promises';
import { dirname, extname, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createSyncHandler, createNotesHandler, createFileStore, storeFromEnvironment } from './lib/sync.mjs';

const directory = dirname(fileURLToPath(import.meta.url));
const csp = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; manifest-src 'self'; worker-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'";
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8', '.webmanifest': 'application/manifest+json; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf', '.otf': 'font/otf' };

export function createLocalServer({ token, store, env = process.env, publicDirectory = resolve(directory, 'public') } = {}) {
  const sync = createSyncHandler({ token, store, env });
  const notes = createNotesHandler({ token, store, env });
  const root = resolve(publicDirectory);
  return createServer(async (req, res) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Content-Security-Policy', csp);
    res.setHeader('Cache-Control', 'no-cache');
    let pathname;
    try { pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname); }
    catch { res.statusCode = 400; return res.end('Invalid path.'); }
    if (pathname === '/api/sync') return sync(req, res);
    if (pathname === '/api/notes') return notes(req, res);
    if (!['GET', 'HEAD'].includes(req.method)) { res.statusCode = 405; res.setHeader('Allow', 'GET, HEAD'); return res.end('Method not allowed.'); }
    const path = resolve(root, `.${pathname === '/' ? '/index.html' : pathname}`);
    if (!path.startsWith(root + sep) || pathname.split('/').some(segment => segment.startsWith('.')) || !types[extname(path)]) { res.statusCode = 404; return res.end('Not found.'); }
    try {
      // Resolve symlinks too so a public directory cannot expose a private file.
      const actual = await realpath(path);
      const actualRoot = await realpath(root);
      if (!actual.startsWith(actualRoot + sep)) { res.statusCode = 404; return res.end('Not found.'); }
      const content = await readFile(actual);
      res.setHeader('Content-Type', types[extname(path)]);
      res.setHeader('Content-Length', content.length);
      res.end(req.method === 'HEAD' ? undefined : content);
    } catch { res.statusCode = 404; res.end('Not found.'); }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (!process.env.NOTY_SYNC_TOKEN || process.env.NOTY_SYNC_TOKEN.length < 32) {
    console.error('Set NOTY_SYNC_TOKEN to a private key of at least 32 characters before starting Noty sync.');
    process.exitCode = 1;
  } else {
    const store = process.env.UPSTASH_REDIS_REST_URL || process.env.UPSTASH_REDIS_REST_TOKEN || process.env.KV_REST_API_URL || process.env.KV_REST_API_TOKEN
      ? storeFromEnvironment(process.env)
      : createFileStore(process.env.NOTY_SYNC_FILE || resolve(directory, '.data/tasks.json'));
    const host = process.env.NOTY_SYNC_HOST || '127.0.0.1';
    const port = Number(process.env.PORT || 8787);
    const server = createLocalServer({ store });
    server.listen(port, host, () => console.log(`Noty sync listening at http://${host}:${server.address().port}`));
  }
}
