const CACHE = 'noty-mobile-shell-v2';
const SHELL = ['/', '/index.html', '/style.css', '/app.mjs', '/queue.mjs', '/notes-queue.mjs', '/note-text.mjs', '/manifest.webmanifest', '/icon.svg', '/fonts/IBMPlexMono-Regular.ttf', '/fonts/DepartureMono-Regular.otf'];
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key.startsWith('noty-mobile-shell-') && key !== CACHE).map(key => caches.delete(key)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  // Credentials and task data are never placed in the service-worker cache.
  if (event.request.method !== 'GET' || url.origin !== self.location.origin || url.search || !SHELL.includes(url.pathname)) return;
  event.respondWith(fetch(event.request).catch(() => caches.match(url.pathname).then(cached => cached || Response.error())));
});
