import { Controller } from "@hotwired/stimulus"

const STORAGE_KEY = "coplan:content-nav-visible"

export default class extends Controller {
  static targets = ["sidebar", "list", "content", "toggleBtn", "showBtn"]
  static values = { visible: { type: Boolean, default: true } }

  connect() {
    const stored = localStorage.getItem(STORAGE_KEY)
    if (stored !== null) {
      this.visibleValue = stored === "true"
    }

    this.buildToc()
    this.setupScrollTracking()

    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)

    this._handleAnchorsUpdated = () => this.updateCommentBadges()
    this.element.addEventListener("coplan:anchors-updated", this._handleAnchorsUpdated)
  }

  disconnect() {
    if (this._scrollHandler) {
      window.removeEventListener("scroll", this._scrollHandler)
    }
    document.removeEventListener("keydown", this.handleKeydown)
    if (this._handleAnchorsUpdated) {
      this.element.removeEventListener("coplan:anchors-updated", this._handleAnchorsUpdated)
    }
  }

  buildToc() {
    const rendered = this.contentTarget.querySelector(".markdown-rendered")
    if (!rendered) return

    this.listTarget.innerHTML = ""
    this._itemsById = new Map()
    this._headings = Array.from(rendered.querySelectorAll("h1, h2, h3"))

    if (this._headings.length === 0) {
      this.sidebarTarget.style.display = "none"
      if (this.hasShowBtnTarget) this.showBtnTarget.style.display = "none"
      return
    }
    this.sidebarTarget.style.display = ""
    if (this.hasShowBtnTarget) this.showBtnTarget.style.display = ""

    const usedIds = new Set()

    this._headings.forEach((heading, index) => {
      let baseId = heading.id || this.slugify(heading.textContent) || `section-${index + 1}`
      let id = baseId
      let suffix = 2
      while (usedIds.has(id)) {
        id = `${baseId}-${suffix++}`
      }
      heading.id = id
      usedIds.add(id)

      const li = document.createElement("li")
      li.className = `content-nav__item content-nav__item--${heading.tagName.toLowerCase()}`
      li.dataset.headingId = id

      const a = document.createElement("a")
      a.className = "content-nav__link"
      a.href = `#${id}`
      a.addEventListener("click", (e) => this.handleLinkClick(e, heading))

      const text = document.createElement("span")
      text.className = "content-nav__link-text"
      text.textContent = heading.textContent
      a.appendChild(text)

      li.appendChild(a)
      this.listTarget.appendChild(li)
      this._itemsById.set(id, li)
    })

    this.updateCommentBadges()
  }

  slugify(text) {
    return text
      .toLowerCase()
      .replace(/\s+/g, "-")
      .replace(/[^a-z0-9-]/g, "")
      .replace(/-{2,}/g, "-")
      .replace(/^-|-$/g, "")
  }

  setupScrollTracking() {
    if (!this._headings || this._headings.length === 0) return

    this._scrollHandler = () => {
      if (this._ignoreScroll) {
        clearTimeout(this._scrollEndTimer)
        this._scrollEndTimer = setTimeout(() => {
          this._ignoreScroll = false
        }, 100)
        return
      }
      if (!this._scrollTicking) {
        requestAnimationFrame(() => {
          this._updateActiveFromScroll()
          this._scrollTicking = false
        })
        this._scrollTicking = true
      }
    }
    window.addEventListener("scroll", this._scrollHandler, { passive: true })
    this._updateActiveFromScroll()
  }

  _updateActiveFromScroll() {
    const threshold = 100
    let active = null
    for (const heading of this._headings) {
      if (heading.getBoundingClientRect().top <= threshold) {
        active = heading
      } else {
        break
      }
    }

    const id = active?.id || this._headings[0]?.id
    if (id && id !== this._activeHeadingId) {
      this._activeHeadingId = id
      this._setActiveLink(id)
    }
  }

  handleLinkClick(event, heading) {
    event.preventDefault()
    history.replaceState(null, "", `#${heading.id}`)

    this._ignoreScroll = true
    this._activeHeadingId = heading.id
    this._setActiveLink(heading.id)

    heading.scrollIntoView({ behavior: "smooth", block: "start" })
  }

  _setActiveLink(id) {
    this.listTarget.querySelectorAll(".content-nav__link").forEach(link => {
      link.classList.remove("content-nav__link--active")
    })

    const item = this._itemsById?.get(id)
    const link = item?.querySelector(".content-nav__link")
    if (link) {
      link.classList.add("content-nav__link--active")
      link.scrollIntoView({ block: "nearest" })
    }
  }

  toggle() {
    this.visibleValue = !this.visibleValue
    localStorage.setItem(STORAGE_KEY, this.visibleValue)
  }

  visibleValueChanged() {
    if (!this.hasSidebarTarget) return

    const hidden = !this.visibleValue
    this.sidebarTarget.classList.toggle("content-nav--hidden", hidden)
    this.sidebarTarget.setAttribute("aria-hidden", String(hidden))
    if (hidden) {
      this.sidebarTarget.setAttribute("inert", "")
    } else {
      this.sidebarTarget.removeAttribute("inert")
    }

    if (this.hasToggleBtnTarget) {
      this.toggleBtnTarget.setAttribute("aria-expanded", String(this.visibleValue))
    }
  }

  handleKeydown(event) {
    const tag = event.target.tagName
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || event.target.isContentEditable) return
    if (event.metaKey || event.ctrlKey || event.altKey) return

    if (event.key === "]") {
      event.preventDefault()
      this.toggle()
    }
  }

  updateCommentBadges() {
    if (!this._headings || this._headings.length === 0) return

    const rendered = this.contentTarget.querySelector(".markdown-rendered")
    if (!rendered) return

    this._headings.forEach((heading, index) => {
      const nextHeading = this._headings[index + 1]
      const threads = this.collectThreadsBetween(heading, nextHeading, rendered)

      let pendingCount = 0
      let todoCount = 0
      threads.forEach(status => {
        if (status === "pending") pendingCount++
        else if (status === "todo") todoCount++
      })

      const item = this._itemsById?.get(heading.id)
      if (!item) return

      const existing = item.querySelector(".content-nav__badge")
      if (existing) existing.remove()

      const total = pendingCount + todoCount
      if (total > 0) {
        const badge = document.createElement("span")
        const badgeType = pendingCount > 0 ? "pending" : "todo"
        badge.className = `content-nav__badge content-nav__badge--${badgeType}`
        badge.textContent = total
        item.querySelector(".content-nav__link").appendChild(badge)
      }
    })
  }

  collectThreadsBetween(startHeading, endHeading, container) {
    const seen = new Set()
    const threads = []
    let collecting = false
    const walker = document.createTreeWalker(container, NodeFilter.SHOW_ELEMENT, null)

    let node
    while ((node = walker.nextNode())) {
      if (node === startHeading) {
        collecting = true
        continue
      }
      if (endHeading && node === endHeading) break

      if (collecting && node.tagName === "MARK" && node.classList.contains("anchor-highlight--open")) {
        const threadId = node.dataset.threadId
        if (threadId && !seen.has(threadId)) {
          seen.add(threadId)
          const status = node.classList.contains("anchor-highlight--pending") ? "pending" : "todo"
          threads.push(status)
        }
      }
    }

    return threads
  }
}
