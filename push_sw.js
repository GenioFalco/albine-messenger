// Custom service worker: push notifications only. Flutter's own generated
// service worker (disabled at build time via --pwa-strategy=none — see
// .github/workflows/deploy.yml) only does asset pre-caching and has no push
// support; a given scope can only ever have one active controller, so
// registering this one replaces that instead of living alongside it. The
// trade-off (no offline asset caching) is accepted in exchange for real push
// notifications.
//
// The notification body is always a generic "Новое сообщение" — this app is
// strict end-to-end encrypted, so the server (and therefore the push
// payload) never has the actual message plaintext to put here. See
// ROADMAP.md's M4 section.

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let data = { title: 'Albine', body: 'Новое сообщение' };
  try {
    if (event.data) {
      data = event.data.json();
    }
  } catch (_) {
    // Not JSON — keep the generic default text above.
  }

  event.waitUntil(
    self.registration.showNotification(data.title || 'Albine', {
      body: data.body || 'Новое сообщение',
      icon: 'icons/Icon-192.png',
      badge: 'icons/Icon-192.png',
      data: { url: data.url || './' },
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = (event.notification.data && event.notification.data.url) || './';
  event.waitUntil(
    self.clients
      .matchAll({ type: 'window', includeUncontrolled: true })
      .then((clients) => {
        for (const client of clients) {
          if ('focus' in client) return client.focus();
        }
        if (self.clients.openWindow) return self.clients.openWindow(targetUrl);
        return undefined;
      })
  );
});
