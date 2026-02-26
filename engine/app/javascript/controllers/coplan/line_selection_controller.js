import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.anchorLine = null
    this.startLine = null
    this.endLine = null
    this.element.addEventListener("click", this.handleClick.bind(this))
  }

  disconnect() {
    this.element.removeEventListener("click", this.handleClick.bind(this))
  }

  handleClick(event) {
    const lineEl = event.target.closest(".line-view__line")
    if (!lineEl) return

    const lineNum = parseInt(lineEl.dataset.line, 10)

    if (event.shiftKey && this.anchorLine !== null) {
      this.startLine = Math.min(this.anchorLine, lineNum)
      this.endLine = Math.max(this.anchorLine, lineNum)
    } else if (this.anchorLine === lineNum && this.startLine === lineNum && this.endLine === lineNum) {
      // Toggle off single selected line
      this.anchorLine = null
      this.startLine = null
      this.endLine = null
    } else {
      this.anchorLine = lineNum
      this.startLine = lineNum
      this.endLine = lineNum
    }

    this.updateSelection()
  }

  updateSelection() {
    this.element.querySelectorAll(".line-view__line").forEach(el => {
      const num = parseInt(el.dataset.line, 10)
      if (this.startLine !== null && num >= this.startLine && num <= this.endLine) {
        el.classList.add("line-view__line--selected")
      } else {
        el.classList.remove("line-view__line--selected")
      }
    })

    this.updateActionBar()
  }

  updateActionBar() {
    let bar = this.element.querySelector(".line-selection-bar")

    if (this.startLine === null) {
      if (bar) bar.remove()
      return
    }

    if (!bar) {
      bar = document.createElement("div")
      bar.classList.add("line-selection-bar")
      this.element.appendChild(bar)
    }

    const rangeText = this.startLine === this.endLine
      ? `Line ${this.startLine} selected`
      : `Lines ${this.startLine}–${this.endLine} selected`

    bar.innerHTML = `
      <span class="line-selection-bar__info">${rangeText}</span>
      <span class="line-selection-bar__actions">
        <a href="#" class="btn btn--primary btn--sm" data-action="line-selection#addComment">Add Comment</a>
        <button type="button" class="btn btn--secondary btn--sm" data-action="line-selection#clearSelection">Clear</button>
      </span>
    `
  }

  addComment(event) {
    event.preventDefault()
    const startInput = document.getElementById("comment_start_line")
    const endInput = document.getElementById("comment_end_line")
    const indicator = document.getElementById("comment-line-indicator")
    const indicatorText = document.getElementById("comment-line-text")
    const textarea = document.getElementById("comment_thread_body_markdown")

    if (startInput && endInput) {
      startInput.value = this.startLine
      endInput.value = this.endLine

      if (indicator && indicatorText) {
        const text = this.startLine === this.endLine
          ? `Commenting on Line ${this.startLine}`
          : `Commenting on Lines ${this.startLine}–${this.endLine}`
        indicatorText.textContent = text
        indicator.style.display = "block"
      }

      if (textarea) {
        textarea.focus()
        textarea.scrollIntoView({ behavior: "smooth", block: "center" })
      }
    }
  }

  clearSelection(event) {
    if (event) event.preventDefault()
    this.anchorLine = null
    this.startLine = null
    this.endLine = null
    this.updateSelection()
  }
}
