// Web Push API helpers shared by Stimulus controllers (settings UI, banner).
// No DOM, no Stimulus — pure functions over navigator.serviceWorker / PushManager.

export function isSupported() {
  return (
    "serviceWorker" in navigator &&
    "PushManager" in window &&
    "Notification" in window &&
    vapidPublicKey() !== null
  )
}

export function permission() {
  return ("Notification" in window) ? Notification.permission : "unsupported"
}

export async function isSubscribed() {
  if (!isSupported()) return false
  const reg = await getRegistration()
  if (!reg) return false
  const sub = await reg.pushManager.getSubscription()
  return !!sub
}

// Prompt for permission, register the SW, subscribe via PushManager,
// and POST the subscription to the engine. Returns the subscription or throws.
export async function subscribe() {
  if (!isSupported()) throw new Error("Web Push not supported in this browser")

  const perm = await Notification.requestPermission()
  if (perm !== "granted") throw new Error(`Notification permission ${perm}`)

  const reg = await registerServiceWorker()
  const existing = await reg.pushManager.getSubscription()
  const subscription = existing || await reg.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: urlBase64ToUint8Array(vapidPublicKey())
  })

  await postSubscription(subscription)
  return subscription
}

// Unsubscribe locally and tell the server to forget us. Returns true if
// anything was actually unsubscribed.
export async function unsubscribe() {
  if (!("serviceWorker" in navigator)) return false
  const reg = await getRegistration()
  if (!reg) return false
  const sub = await reg.pushManager.getSubscription()
  if (!sub) return false

  await deleteSubscription(sub)
  await sub.unsubscribe()
  return true
}

// ---- internals ----

function vapidPublicKey() {
  return document.head.querySelector("meta[name='coplan-vapid-public-key']")?.content || null
}

function serviceWorkerUrl() {
  return document.head.querySelector("meta[name='coplan-service-worker-url']")?.content || null
}

function csrfToken() {
  return document.head.querySelector("meta[name='csrf-token']")?.content || ""
}

async function getRegistration() {
  const url = serviceWorkerUrl()
  if (!url) return null
  return await navigator.serviceWorker.getRegistration(url) ||
         await navigator.serviceWorker.getRegistration()
}

async function registerServiceWorker() {
  const url = serviceWorkerUrl()
  if (!url) throw new Error("Service worker URL meta tag missing")
  await navigator.serviceWorker.register(url)
  // register() resolves as soon as the SW is *registered*, but PushManager
  // needs it to be *active*. ready resolves with the registration once any
  // SW for the current page's scope reaches active state.
  return await navigator.serviceWorker.ready
}

async function postSubscription(subscription) {
  const json = subscription.toJSON()
  const response = await fetch(endpointUrl(), {
    method: "POST",
    headers: headers(),
    credentials: "same-origin",
    body: JSON.stringify({ subscription: json })
  })
  if (!response.ok) throw new Error(`Subscription POST failed: ${response.status}`)
}

async function deleteSubscription(subscription) {
  const json = subscription.toJSON()
  const response = await fetch(endpointUrl(), {
    method: "DELETE",
    headers: headers(),
    credentials: "same-origin",
    body: JSON.stringify({ subscription: { endpoint: json.endpoint } })
  })
  // 404 is fine — server already had nothing to delete.
  if (!response.ok && response.status !== 404) {
    throw new Error(`Subscription DELETE failed: ${response.status}`)
  }
}

function endpointUrl() {
  // Engine mount point is the directory of the SW URL — works no matter
  // where the host mounts CoPlan.
  const swUrl = serviceWorkerUrl()
  const base = swUrl.replace(/\/coplan_service_worker\.js$/, "")
  return `${base}/web_push/subscription`
}

function headers() {
  return {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "X-CSRF-Token": csrfToken()
  }
}

// VAPID public key arrives as URL-safe base64; PushManager wants Uint8Array.
function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - base64String.length % 4) % 4)
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(base64)
  const output = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) output[i] = raw.charCodeAt(i)
  return output
}
