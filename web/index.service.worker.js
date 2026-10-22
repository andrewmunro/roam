// Replaces the Godot PWA service worker that older builds installed (it served cached
// builds after a deploy). Browsers fetch this on their next update check: it clears the
// caches, unregisters itself and reloads open pages so they load the current build.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
	event.waitUntil((async () => {
		for (const key of await caches.keys()) {
			await caches.delete(key);
		}
		await self.registration.unregister();
		for (const client of await self.clients.matchAll({ type: 'window' })) {
			client.navigate(client.url);
		}
	})());
});
