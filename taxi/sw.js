// المنصور تاكسي: service worker so the customer page can be installed on the phone.
// No caching: every request goes to the network, so updates show up straight away.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", () => {});
