// تكسي مجمع المنصور: service worker — lets the page be installed and receive push notifications.
// No caching: every request goes to the network, so updates show up straight away.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", () => {});
self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || "تكسي مجمع المنصور", {
    body: d.body || "", tag: d.tag || "taxi", renotify: true, dir: "rtl", lang: "ar",
    icon: "img/apple-touch-icon.png", badge: "img/favicon.png", vibrate: [300, 120, 300],
    data: { url: d.url || "./#order" }
  }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "./", self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
    for (const c of list) if (c.url.split("#")[0] === url.split("#")[0] && "focus" in c) { c.navigate(url).catch(() => {}); return c.focus(); }
    return self.clients.openWindow(url);
  }));
});
