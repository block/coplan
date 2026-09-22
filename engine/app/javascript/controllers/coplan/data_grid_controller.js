import { Controller } from "@hotwired/stimulus"
import { openExpander, attachExpandAffordance, nearestHeading, ICONS } from "coplan/expander"

// A markdown table, twice over.
//
// In the document it stays compact and well-behaved: columns sized to their
// content, long cells wrapped, a scroll frame so a wide table can never run
// off the page, a header that pins itself when the table is tall enough to
// scroll, and fades at the edges so it's obvious there's more.
//
// Expanded it becomes a spreadsheet: header row and first column pinned, a
// cell cursor you drive with the arrow keys, a crosshair on the current row
// and column, on-demand row expansion for reading long values, and sortable
// columns. The surface itself is shared with Mermaid diagrams — see
// coplan/expander.

// Below these, a table is small enough that offering to expand it is noise.
const WORTH_EXPANDING_ROWS = 8
const WORTH_EXPANDING_COLUMNS = 4

export default class extends Controller {
  static targets = [ "frame" ]

  connect() {
    this.table = this.frameTarget.querySelector("table")
    if (!this.table) return

    this.onScroll = () => this.measure()
    this.frameTarget.addEventListener("scroll", this.onScroll, { passive: true })
    this.observer = new ResizeObserver(() => this.measure())
    this.observer.observe(this.frameTarget)
    this.observer.observe(this.table)

    this.affordance = attachExpandAffordance(this.element, {
      label: "Expand table",
      hint: "Expand table",
      className: "data-grid__expand",
      onExpand: () => this.expand()
    })

    this.measure()
  }

  disconnect() {
    this.frameTarget?.removeEventListener("scroll", this.onScroll)
    this.observer?.disconnect()
    this.expanded?.close()
  }

  // Edge fades and the expand affordance both depend on whether the frame
  // actually has more to show than it's showing.
  measure() {
    const frame = this.frameTarget
    const overflowX = frame.scrollWidth - frame.clientWidth > 1
    const overflowY = frame.scrollHeight - frame.clientHeight > 1

    this.element.classList.toggle("is-scrolled-start", frame.scrollLeft > 1)
    this.element.classList.toggle("is-scrolled-end",
      overflowX && Math.ceil(frame.scrollLeft + frame.clientWidth) < frame.scrollWidth - 1)
    this.element.classList.toggle("is-tall", overflowY)

    const rows = this.table.rows.length
    const columns = this.table.rows[0]?.cells.length || 0
    this.element.classList.toggle("is-expandable",
      overflowX || overflowY || rows > WORTH_EXPANDING_ROWS || columns > WORTH_EXPANDING_COLUMNS)
  }

  expandFromDoubleClick(event) {
    if (event.target.closest("a, button, input, textarea, select, [contenteditable], [data-source-badge], .anchor-highlight")) return
    event.preventDefault()
    window.getSelection()?.removeAllRanges()
    const cell = event.target.closest("td, th")
    const position = cell && cell.closest("table") === this.table ? {
      row: cell.closest("thead") ? -1 : Array.from(this.table.tBodies[0]?.rows || []).indexOf(cell.parentElement),
      column: cell.cellIndex
    } : null
    this.expand(position)
  }

  expand(position = null) {
    if (this.expanded) return

    const expander = openExpander({
      title: nearestHeading(this.element) || "Table",
      label: "Expanded table",
      variant: "grid",
      container: this.element.closest('[data-controller~="coplan--source-comments"]') || document.body,
      status: true,
      onClose: () => { this.expanded = null; this.sheet = null }
    })
    this.expanded = expander
    this.sheet = new Sheet(this.table, expander, position)
    expander.dialog.dispatchEvent(new CustomEvent("coplan:expander-opened", { bubbles: true }))
  }
}

// The expanded spreadsheet. Owns a clone of the document's table, so
// sorting and the cursor never touch what the page (or a comment anchor)
// is looking at.
class Sheet {
  constructor(sourceTable, expander, position) {
    this.expander = expander
    this.table = sourceTable.cloneNode(true)
    this.table.className = "data-sheet__table"
    this.table.setAttribute("role", "grid")

    this.headerCells = Array.from(this.table.tHead?.rows[0]?.cells || [])
    this.bodyRows = Array.from(this.table.tBodies[0]?.rows || [])
    this.sourceOrder = this.bodyRows.slice()
    this.prose = this.bodyRows.some(row => Array.from(row.cells).some(cell =>
      cellText(cell).length > 120 || cell.querySelector("br, pre, ul, ol")))
    this.columnCount = this.headerCells.length || this.bodyRows[0]?.cells.length || 0
    this.sort = null
    this.cursor = null

    this.build()
    this.wire()
    if (position) this.moveTo(position.row, position.column)
    else if (this.bodyRows.length > 0) this.moveTo(0, 0)
    else this.frame.focus({ preventScroll: true })
  }

  build() {
    // A <col> per column is what makes the crosshair free: a class on one
    // <col> paints the whole column, with no per-cell bookkeeping on a
    // table that could be hundreds of rows long.
    const group = document.createElement("colgroup")
    this.columns = Array.from({ length: this.columnCount }, () => {
      const col = document.createElement("col")
      group.append(col)
      return col
    })
    this.table.prepend(group)

    this.headerCells.forEach((cell, index) => {
      cell.setAttribute("scope", "col")
      cell.dataset.column = index
      cell.setAttribute("aria-sort", "none")
      cell.tabIndex = 0
      const sortButton = node("button", "data-sheet__sort")
      sortButton.type = "button"
      sortButton.textContent = "↕"
      sortButton.setAttribute("aria-label", `Sort by ${cellText(cell) || index + 1}`)
      sortButton.addEventListener("click", event => {
        event.stopPropagation()
        this.applySort(this.nextSortFor(index))
      })
      cell.append(sortButton)
    })

    this.bodyRows.forEach(row => {
      Array.from(row.cells).forEach((cell, index) => {
        cell.dataset.column = index
        cell.tabIndex = -1
        cell.setAttribute("role", "gridcell")
      })
    })

    this.frame = node("div", "data-sheet__frame")
    this.frame.classList.toggle("is-wrapped", this.prose)
    this.frame.tabIndex = 0
    this.frame.append(this.table)

    const sheet = node("div", "data-sheet")
    sheet.append(this.frame)
    this.expander.body.append(sheet)

    this.wrapButton = this.expander.addTool({
      label: "Wrap cell text",
      hint: "Wrap cell text",
      icon: ICONS.wrap,
      onClick: () => this.toggleWrap()
    })
    this.wrapButton.classList.toggle("is-active", this.prose)
    this.wrapButton.setAttribute("aria-pressed", String(this.prose))
    this.resetButton = this.expander.addTool({
      label: "Reset sort order",
      hint: "Back to the document's order",
      icon: ICONS.unsort,
      className: "expander__tool expander__tool--hidden",
      onClick: () => this.applySort(null)
    })

    this.address = node("span", "data-sheet__address")
    this.column = node("span", "data-sheet__column")
    this.dimensions = node("span", "data-sheet__dimensions")
    this.dimensions.textContent =
      `${count(this.bodyRows.length, "row")} × ${count(this.columnCount, "column")}`
    const hint = node("span", "expander__hint data-sheet__hint")
    hint.innerHTML = '<kbd>←</kbd><kbd>↑</kbd><kbd>↓</kbd><kbd>→</kbd> Move <span>·</span> <kbd>⌘/Ctrl C</kbd> Copy'
    this.commentButton = node("button", "btn btn--secondary btn--sm data-sheet__comment")
    this.commentButton.type = "button"
    this.commentButton.innerHTML = '<kbd>C</kbd> Comment'
    this.commentButton.dataset.action = "coplan--source-comments#commentOnCell"
    this.commentButton.hidden = !this.table.querySelector("[data-source-target]")
    this.rowButton = node("button", "btn btn--secondary btn--sm data-sheet__row-toggle")
    this.rowButton.type = "button"
    this.rowButton.addEventListener("click", () => this.toggleRow())
    this.expander.setStatus([ this.address, this.column, this.dimensions, hint, this.rowButton, this.commentButton ])
    this.updateRowControl()
  }

  wire() {
    this.table.addEventListener("click", event => {
      const cell = event.target.closest("td, th")
      if (!cell) return
      if (event.target.closest("a, button, [data-source-badge]") || cell.parentElement.parentElement === this.table.tHead) return
      const row = this.bodyRows.indexOf(cell.parentElement)
      if (row >= 0) this.moveTo(row, Number(cell.dataset.column))
    })

    this.frame.addEventListener("keydown", event => this.handleKey(event))
  }

  handleKey(event) {
    if (event.altKey) return

    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "c") {
      if (!this.cursor) return
      event.preventDefault()
      // Only say "copied" once the clipboard has actually taken it: over
      // plain http there's no clipboard API at all, and a flash that lies
      // costs more than one that never appears.
      navigator.clipboard?.writeText(cellText(this.cursor))
        .then(() => this.flashCopied(), () => {})
      return
    }
    if (event.metaKey || event.ctrlKey) return

    if (event.key.toLowerCase() === "r") {
      event.preventDefault()
      this.toggleRow()
      return
    }

    const lastRow = this.bodyRows.length - 1
    const lastColumn = this.columnCount - 1
    const page = Math.max(1, Math.floor(this.frame.clientHeight / (this.cursor?.offsetHeight || 32)) - 1)
    let { row, column } = this.position || { row: 0, column: 0 }

    switch (event.key) {
      case "ArrowUp": row -= 1; break
      case "ArrowDown": row += 1; break
      case "ArrowLeft": column -= 1; break
      case "ArrowRight": column += 1; break
      case "PageUp": row -= page; break
      case "PageDown": row += page; break
      // Home/End move along the row; with shift they jump to the corners of
      // the whole table, the way a spreadsheet's ctrl+Home does (ctrl is
      // already spoken for by copy).
      case "Home":
        column = 0
        if (event.shiftKey) row = 0
        break
      case "End":
        column = lastColumn
        if (event.shiftKey) row = lastRow
        break
      default: return
    }

    event.preventDefault()
    this.moveTo(clamp(row, this.position?.row === -1 ? -1 : 0, lastRow), clamp(column, 0, lastColumn))
  }

  moveTo(row, column) {
    const cell = row === -1 ? this.headerCells[column] : this.bodyRows[row]?.cells[column]
    if (!cell) return

    this.cursor?.classList.remove("is-cursor")
    this.cursor?.removeAttribute("aria-selected")
    this.bodyRows.forEach(candidate => candidate.classList.remove("is-cursor-row"))
    this.columns.forEach(candidate => candidate.classList.remove("is-cursor-column"))
    this.headerCells.forEach(candidate => candidate.classList.remove("is-cursor-column"))

    this.position = { row, column }
    this.cursor = cell
    this.commentButton.disabled = !cell.dataset.sourceTarget
    cell.classList.add("is-cursor")
    cell.setAttribute("aria-selected", "true")
    this.bodyRows[row]?.classList.add("is-cursor-row")
    this.columns[column]?.classList.add("is-cursor-column")
    this.headerCells[column]?.classList.add("is-cursor-column")

    this.address.textContent = `${columnName(column)}${row === -1 ? "" : row + 1}`
    const header = cellText(this.headerCells[column])
    this.column.textContent = header || ""
    this.column.hidden = !header

    this.updateRowControl()

    cell.focus({ preventScroll: true })
    this.reveal(cell)
  }

  // Focus scrolls a cell into view on its own, but it doesn't know the
  // pinned header and first column are sitting on top of the region it
  // scrolled to — so it happily parks the cursor underneath them.
  reveal(cell) {
    const frame = this.frame.getBoundingClientRect()
    const box = cell.getBoundingClientRect()
    const headerHeight = this.position.row === -1 ? 0 : (this.table.tHead?.getBoundingClientRect().height || 0)
    const gutter = this.position.column === 0 ? 0 : (this.bodyRows[0]?.cells[0]?.getBoundingClientRect().width || 0)

    let left = 0
    let top = 0
    if (box.height > frame.height - headerHeight || box.top < frame.top + headerHeight) top = box.top - frame.top - headerHeight
    else if (box.bottom > frame.bottom) top = box.bottom - frame.bottom
    if (this.position.column === 0) left = -this.frame.scrollLeft
    else if (box.left < frame.left + gutter) left = box.left - frame.left - gutter
    else if (box.right > frame.right) left = box.right - frame.right

    if (left || top) this.frame.scrollBy({ left, top, behavior: "instant" })
  }

  nextSortFor(column) {
    if (this.sort?.column !== column) return { column, direction: "asc" }
    return this.sort.direction === "asc" ? { column, direction: "desc" } : null
  }

  applySort(sort) {
    this.sort = sort
    const body = this.table.tBodies[0]
    if (!body) return

    if (sort) {
      const values = new Map(this.sourceOrder.map(row =>
        [ row, cellText(row.cells[sort.column]) ]))
      const numeric = this.sourceOrder.every(row => isNumeric(values.get(row)))
      const order = sort.direction === "asc" ? 1 : -1
      this.bodyRows = this.sourceOrder.slice().sort((a, b) => {
        const left = values.get(a)
        const right = values.get(b)
        // Blanks sort last in both directions — a missing value isn't
        // "smallest", it's absent.
        if (left === "" || right === "") return left === right ? 0 : left === "" ? 1 : -1
        if (numeric) return (numberOf(left) - numberOf(right)) * order
        return left.localeCompare(right, undefined, { numeric: true, sensitivity: "base" }) * order
      })
    } else {
      this.bodyRows = this.sourceOrder.slice()
    }

    body.append(...this.bodyRows)
    this.headerCells.forEach((cell, index) => {
      const active = sort?.column === index
      cell.setAttribute("aria-sort", active ? (sort.direction === "asc" ? "ascending" : "descending") : "none")
      cell.classList.toggle("is-sorted-asc", active && sort.direction === "asc")
      cell.classList.toggle("is-sorted-desc", active && sort.direction === "desc")
    })
    this.resetButton.classList.toggle("expander__tool--hidden", !sort)

    // The cursor follows its cell, not its coordinates — the value you were
    // looking at is the thing you care about after a re-sort.
    if (this.cursor) {
      const row = this.bodyRows.indexOf(this.cursor.parentElement)
      if (row >= 0) this.moveTo(row, this.position.column)
    }
  }

  toggleWrap() {
    const wrapped = this.frame.classList.toggle("is-wrapped")
    this.wrapButton.classList.toggle("is-active", wrapped)
    this.wrapButton.setAttribute("aria-pressed", String(wrapped))
    this.updateRowControl()
    // Hand the keyboard back to the grid: the arrow keys only reach the
    // sheet's own listener while focus is inside the frame, so leaving it on
    // the toolbar button would strand the cursor.
    if (this.cursor) {
      this.cursor.focus({ preventScroll: true })
      this.reveal(this.cursor)
    }
  }

  toggleRow() {
    if (!this.cursor || this.position.row === -1 || this.frame.classList.contains("is-wrapped")) return
    this.cursor.parentElement.classList.toggle("is-expanded")
    this.updateRowControl()
    this.cursor.focus({ preventScroll: true })
    this.reveal(this.cursor)
  }

  updateRowControl() {
    this.rowButton.hidden = this.frame.classList.contains("is-wrapped")
    this.rowButton.disabled = !this.cursor || this.position.row === -1
    const expanded = this.cursor?.parentElement.classList.contains("is-expanded") || false
    this.rowButton.setAttribute("aria-expanded", String(expanded))
    this.rowButton.innerHTML = `<kbd>R</kbd> ${expanded ? "Collapse" : "Expand"} row`
  }

  flashCopied() {
    this.address.classList.add("is-copied")
    setTimeout(() => this.address.classList.remove("is-copied"), 600)
  }
}

function node(name, className) {
  const element = document.createElement(name)
  element.className = className
  return element
}

function clamp(value, low, high) {
  return Math.min(high, Math.max(low, value))
}

function count(n, noun) {
  return `${n} ${noun}${n === 1 ? "" : "s"}`
}

// Spreadsheet column names: A, B, … Z, AA, AB.
function columnName(index) {
  let name = ""
  let n = index
  do {
    name = String.fromCharCode(65 + (n % 26)) + name
    n = Math.floor(n / 26) - 1
  } while (n >= 0)
  return name
}

// Table numbers in plans wear units: "$1,200", "38%", "12ms", "~4". A column
// counts as numeric only if every value in it reads as one, so a column of
// names never gets sorted by the digits inside it.
const NUMERIC = /^[^\d-]{0,3}-?[\d,]+(\.\d+)?[^\d]{0,4}$/

function isNumeric(value) {
  return value === "" || NUMERIC.test(value)
}

function numberOf(value) {
  return Number.parseFloat(value.replace(/[^\d.-]/g, "")) || 0
}

// Comment badges and sorting controls are UI, never spreadsheet data.
function cleanCell(cell) {
  const copy = cell.cloneNode(true)
  copy.querySelectorAll("[data-source-badge], button").forEach(el => el.remove())
  return copy
}

function cellText(cell) {
  return cell ? cleanCell(cell).textContent.trim() : ""
}
