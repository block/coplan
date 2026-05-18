import { Controller } from "@hotwired/stimulus"

/*
 * coplan--live-update
 *
 * Listens for the custom <turbo-stream action="coplan-replace-if-clean">
 * payloads broadcast by Broadcaster#replace_plan_content. When an agent
 * (or anyone) commits a new revision elsewhere, the server pushes the new
 * rendered body to every open tab. This controller decides what to do:
 *
 *   * If the user has no unsaved drafts → swap the body in place. Existing
 *     Stimulus controllers reconnect over the new DOM, comment highlights
 *     re-attach.
 *
 *   * If the user is mid-edit (any textarea on the page has non-empty,
 *     non-trim-blank text) → DON'T blow away their typing. Instead, show
 *     a sticky banner above the content: "This plan was updated to
 *     revision N. Reload to see the latest." with a button that reloads.
 *
 * The custom Turbo Stream action is registered exactly once per page —
 * we use a window-level flag so multiple live-update controllers (one per
 * plan body) don't fight each other.
 */
export default class extends Controller {
  static values = {
    revision: Number
  }

  connect() {
    this.constructor.registerStreamAction()
  }

  static registerStreamAction() {
    if (typeof window === "undefined") return
    if (window.__coplanLiveUpdateRegistered) return
    if (typeof window.Turbo === "undefined" || !window.Turbo.StreamActions) {
      // Turbo not ready yet — try again once it loads.
      document.addEventListener("turbo:load", () => this.registerStreamAction(), { once: true })
      return
    }

    window.Turbo.StreamActions["coplan-replace-if-clean"] = function () {
      // `this` is the <turbo-stream> element. Standard Turbo API.
      const targetId = this.getAttribute("target")
      const incomingRevision = parseInt(this.getAttribute("data-revision"), 10) || null
      const target = document.getElementById(targetId)
      if (!target) return

      // If the local DOM is already at this revision (or newer), skip — this
      // tab is the one that issued the edit, no need to re-render.
      const currentRevision = parseInt(target.getAttribute("data-coplan--live-update-revision-value"), 10) || 0
      if (incomingRevision && currentRevision >= incomingRevision) return

      // `templateContent` is a DocumentFragment — it has no `innerHTML`.
      // Use replaceChildren(fragment) to swap the contents of target in one
      // shot. Stimulus controllers inside target will disconnect + reconnect.
      const fragment = this.templateContent

      if (hasDirtyDrafts()) {
        showStaleBanner(target, incomingRevision)
      } else {
        target.replaceChildren(fragment)
        if (incomingRevision) {
          target.setAttribute("data-coplan--live-update-revision-value", String(incomingRevision))
        }
        clearStaleBanner()
      }
    }

    window.__coplanLiveUpdateRegistered = true
  }
}

/*
 * Returns true if ANY textarea or contenteditable on the page contains
 * user-typed text. Used to decide whether it's safe to blow away the
 * rendered body. We're conservative: if even one textarea has trimmed
 * non-empty text, we treat the page as dirty.
 */
function hasDirtyDrafts() {
  const textareas = document.querySelectorAll("textarea")
  for (const ta of textareas) {
    if (ta.value && ta.value.trim().length > 0) return true
  }
  const editables = document.querySelectorAll("[contenteditable='true']")
  for (const el of editables) {
    if (el.textContent && el.textContent.trim().length > 0) return true
  }
  return false
}

function showStaleBanner(targetEl, revision) {
  let banner = document.getElementById("plan-stale-banner")
  if (banner) {
    // Already showing — just bump the revision number.
    const span = banner.querySelector("[data-revision]")
    if (span && revision) span.textContent = String(revision)
    return
  }

  banner = document.createElement("div")
  banner.id = "plan-stale-banner"
  banner.className = "plan-stale-banner"
  banner.setAttribute("role", "status")
  banner.setAttribute("aria-live", "polite")
  banner.innerHTML = `
    <div class="plan-stale-banner__message">
      ⚠️ This plan was updated${revision ? ` (now at revision <strong data-revision>${revision}</strong>)` : ""}.
      Your draft is preserved here — reload to see the latest version.
    </div>
    <button type="button" class="btn btn--primary btn--sm plan-stale-banner__reload">Reload</button>
  `
  banner.querySelector(".plan-stale-banner__reload").addEventListener("click", () => {
    window.location.reload()
  })

  // Insert directly above the stale content so the connection is visually obvious.
  targetEl.parentNode.insertBefore(banner, targetEl)
}

function clearStaleBanner() {
  const banner = document.getElementById("plan-stale-banner")
  if (banner) banner.remove()
}
