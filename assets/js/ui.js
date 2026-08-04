// Behaviour that needs no LiveView socket. Bundled into app.js for interactive
// pages and served on its own to everyone else, so it lives in one place.

function isEditable(target) {
  return !!target && (target.isContentEditable ||
    target.tagName === "INPUT" ||
    target.tagName === "TEXTAREA" ||
    target.tagName === "SELECT")
}

// Close the user menu <details> when clicking outside of it.
document.addEventListener("click", (event) => {
  let menu = document.getElementById("app-user-menu")
  if (!menu || !menu.open) return
  if (menu.contains(event.target)) return
  menu.open = false
})

// Focus the header search input when "/" is pressed outside of an editable element.
document.addEventListener("keydown", (event) => {
  if (event.key !== "/") return
  if (event.ctrlKey || event.metaKey || event.altKey) return
  if (isEditable(event.target)) return

  let input = document.getElementById("page-search-input")
  if (!input) return

  event.preventDefault()
  input.focus()
  input.select()
})

// A row's focus target differs per mode: an anchor for :link, a summary for
// :expandable, and the line itself for :plain. Matching only direct children
// keeps a nested list inside an expanded row out of the parent's cursor.
const ROW_SELECTOR = ":scope > li > .row-line, :scope > li > details > summary"
const LIST_SELECTOR = "ul.row-list[data-keynav]"

// Every marked list on the page is one cursor, in document order — the inbox
// renders a separate list per day, and the cursor should cross them.
function keynavRows() {
  return [...document.querySelectorAll(LIST_SELECTOR)]
    .flatMap((list) => [...list.querySelectorAll(ROW_SELECTOR)])
}

function moveRow(step) {
  let rows = keynavRows()
  if (!rows.length) return false

  // Read the cursor off the focused element rather than storing an index, so
  // clicking or tabbing into a row leaves it where the user put it.
  let index = rows.indexOf(document.activeElement)
  let wanted = index === -1 ? (step > 0 ? 0 : rows.length - 1) : index + step

  let next = rows[Math.min(Math.max(wanted, 0), rows.length - 1)]
  if (!next) return false

  next.focus()
  next.scrollIntoView({block: "nearest"})
  return true
}

const ROW_STEPS = {j: 1, ArrowDown: 1, k: -1, ArrowUp: -1}
const JUMPS = {p: "/packages", o: "/options", c: "/changes", n: "/inbox"}
const CHORD_MS = 1000

let pendingJump = null

function clearPendingJump() {
  clearTimeout(pendingJump)
  pendingJump = null
}

document.addEventListener("keydown", (event) => {
  if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return
  if (isEditable(event.target)) return

  // A pending "g" owns the next key outright, so "g" then "k" jumps rather
  // than moving the cursor.
  if (pendingJump) {
    let destination = JUMPS[event.key]
    clearPendingJump()
    if (destination) {
      event.preventDefault()
      window.location.assign(destination)
    }
    return
  }

  if (event.key === "g") {
    pendingJump = setTimeout(clearPendingJump, CHORD_MS)
    return
  }

  let step = ROW_STEPS[event.key]
  if (step && moveRow(step)) event.preventDefault()
})

// Auto-submit the lens form on dropdown change so the channel applies without
// clicking "Set". The form's phx-change is present in the markup either way but
// inert without a socket, so liveSocket — not the attribute — is what says
// whether LiveView is already handling the change.
document.addEventListener("change", (event) => {
  if (window.liveSocket) return
  if (event.target.matches(".lens__select")) event.target.form.requestSubmit()
})
