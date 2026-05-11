// CoPlan service worker.
// Served by Coplan::ServiceWorkersController#show with Cache-Control: no-cache.
// Default scope is the engine mount point.

self.addEventListener("install", (event) => {
  // Activate immediately on update so notifications use the latest handler.
  self.skipWaiting()
})

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim())
})

// Push payloads are JSON: { title, body, url, tag }
// `tag` groups/dedups notifications (e.g., "comment-thread-#{id}").
// `url` may include a hash for deep-linking to a thread popover.
self.addEventListener("push", (event) => {
  if (!event.data) return

  let payload
  try {
    payload = event.data.json()
  } catch {
    payload = { title: "CoPlan", body: event.data.text() }
  }

  const title = payload.title || "CoPlan"
  const options = {
    body: payload.body || "",
    tag: payload.tag,
    data: { url: payload.url }
  }

  event.waitUntil(self.registration.showNotification(title, options))
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  const targetUrl = event.notification.data?.url
  if (!targetUrl) return

  event.waitUntil((async () => {
    const allClients = await self.clients.matchAll({
      type: "window",
      includeUncontrolled: true
    })

    // Prefer focusing an existing CoPlan tab and navigating it. We compare
    // origins so a CoPlan tab on /plans/foo handles a notification for
    // /plans/bar without spawning a new window.
    const targetUrlObj = new URL(targetUrl, self.location.origin)
    for (const client of allClients) {
      const clientUrl = new URL(client.url)
      if (clientUrl.origin !== targetUrlObj.origin) continue
      if ("focus" in client) {
        await client.focus()
        if ("navigate" in client && client.url !== targetUrlObj.href) {
          await client.navigate(targetUrlObj.href)
        }
        return
      }
    }

    if (self.clients.openWindow) {
      await self.clients.openWindow(targetUrl)
    }
  })())
})
