// Behaviour that needs no LiveView socket. Bundled into app.js for interactive
// pages and served on its own to everyone else, so it lives in one place.

function isTextEntry(target) {
  return !!target && (target.isContentEditable ||
    target.tagName === "INPUT" ||
    target.tagName === "TEXTAREA")
}

function isEditable(target) {
  return isTextEntry(target) || (!!target && target.tagName === "SELECT")
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
  if (document.querySelector("dialog[open]")) return

  let input = document.getElementById("page-search-input")
  if (!input) return

  event.preventDefault()
  input.focus()
  input.select()
})

// Escape hands focus back to the page so row navigation works again. The input
// is type="search", which Chromium and WebKit clear on Escape while keeping
// focus and Firefox ignores entirely, so take the key outright: one press
// always exits, on every engine. Clearing stays with the × link, which
// navigates and so keeps the input and the server's results in step.
document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return
  if (event.target.id !== "page-search-input") return
  // An open dialog owns Escape; closing it must not also blur the box.
  if (document.querySelector("dialog[open]")) return

  event.preventDefault()
  event.target.blur()
})

// The × clears by navigating, which destroys the input, so the intent to focus
// has to outlive the trip. Park it in sessionStorage and pick it up on the far
// side, which covers both the live nav and the full reload an opted-out page
// takes. A modifier click opens the × in another tab and leaves this one where
// it is, so it must not set the flag: nothing here would ever spend it.
const CLEARED_SEARCH = "tracker:cleared-search"

document.addEventListener("click", (event) => {
  if (event.button !== 0) return
  if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return
  if (!event.target.closest?.(".app-search__clear")) return

  sessionStorage.setItem(CLEARED_SEARCH, "1")
})

// The live nav stops page loading twice, first with the header torn out and
// then with the rebuilt one, so hold the flag until the input is back.
function focusClearedSearch() {
  if (!sessionStorage.getItem(CLEARED_SEARCH)) return

  let input = document.getElementById("page-search-input")
  if (!input) return

  sessionStorage.removeItem(CLEARED_SEARCH)
  input.focus()
}

focusClearedSearch()
window.addEventListener("phx:page-loading-stop", focusClearedSearch)

// "#" is Shift+3 on most layouts, so match the character rather than the key
// position, and keep it out of the row-navigation listener below, whose
// shiftKey guard would reject it. Focus only: .focus() cannot pop a native
// select open, and showPicker() is missing from an engine. Arrow keys then
// pick a channel, which the listener below leaves to the select.
document.addEventListener("keydown", (event) => {
  if (event.key !== "#") return
  if (event.ctrlKey || event.metaKey || event.altKey) return
  if (isEditable(event.target)) return
  if (document.querySelector("dialog[open]")) return

  let select = document.getElementById("lens-channel")
  if (!select || select.disabled) return

  event.preventDefault()
  select.focus()
})

// "v" follows the page out to GitHub. A focused row's own link wins over the
// page's, so the cursor decides which PR opens; a page with neither ignores the
// key.
document.addEventListener("keydown", (event) => {
  if (event.key !== "v") return
  if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return
  if (isEditable(event.target)) return
  if (document.querySelector("dialog[open]")) return

  let row = event.target.closest?.("ul.row-list > li")
  let link = row?.querySelector("a[data-external-link]") ||
    document.querySelector("a[data-external-link]")
  if (!link) return

  event.preventDefault()
  window.open(link.href, "_blank", "noopener")
})

// "u" and "h" climb the options prefix tree by clicking the parent link the
// pathbar carries, so the key takes a crumb's exact path: live navigation under
// LiveView, a plain load without it. A page with no pathbar (the options root,
// everywhere else) has nowhere to go.
const UP_KEYS = ["u", "h"]

document.addEventListener("keydown", (event) => {
  if (!UP_KEYS.includes(event.key)) return
  if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return
  if (isEditable(event.target)) return
  if (document.querySelector("dialog[open]")) return

  let parent = document.querySelector("a[data-parent-link]")
  if (!parent) return

  event.preventDefault()
  parent.click()
})

// A row's focus target differs per mode: an anchor for :link, a summary for
// :expandable, and the line itself for :plain.
//
// Every list on the page is one cursor. Selecting rows in a single pass gives
// document order for free, so a page's several lists chain together and a list
// nested in an expanded row falls in at the row it belongs to.
const ROW_SELECTOR = "ul.row-list > li > .row-line, ul.row-list > li > details > summary"

function keynavRows() {
  return [...document.querySelectorAll(ROW_SELECTOR)]
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
const PATCH_MS = 1000

let pendingJump = null

// The chord lands on the same link the chrome offers, so a jump inherits
// whatever the nav carries — the persisted search query, live navigation —
// rather than reimplementing it. A page without the chrome still jumps.
function jumpTo(destination) {
  let link = [...document.querySelectorAll(".app-nav a[href], a.app-inbox[href]")]
    .find((candidate) => new URL(candidate.href).pathname === destination)

  if (link) link.click()
  else window.location.assign(destination)
}

function clearPendingJump() {
  clearTimeout(pendingJump)
  pendingJump = null
}

// "?" is Shift+/ on most layouts, so match the character rather than the key
// position — and check it before the shiftKey guard below rejects it.
document.addEventListener("keydown", (event) => {
  if (event.key !== "?") return
  if (event.ctrlKey || event.metaKey || event.altKey) return
  if (isEditable(event.target)) return

  let dialog = document.getElementById("shortcuts")
  if (!dialog) return

  event.preventDefault()
  if (dialog.open) dialog.close()
  else dialog.showModal()
})

// The house dialog pattern makes the <dialog> itself the full-viewport
// backdrop with a .card inside, so a backdrop click lands on the dialog
// element and anything inside the card lands on a child.
document.addEventListener("click", (event) => {
  let dialog = document.getElementById("shortcuts")
  if (dialog && dialog.open && event.target === dialog) dialog.close()
})

document.addEventListener("keydown", (event) => {
  if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return
  if (isTextEntry(event.target)) return
  // A modal dialog makes the page behind it inert; the cursor stays put.
  if (document.querySelector("dialog[open]")) return

  // A pending "g" owns the next key outright, so "g" then "k" jumps rather
  // than moving the cursor.
  if (pendingJump) {
    let destination = JUMPS[event.key]
    clearPendingJump()
    if (destination) {
      event.preventDefault()
      jumpTo(destination)
    }
    return
  }

  if (event.key === "g") {
    pendingJump = setTimeout(clearPendingJump, CHORD_MS)
    return
  }

  let step = ROW_STEPS[event.key]
  if (!step) return

  // A focused <select> owns its arrow keys — they pick an option, and on the
  // lens that submits. The letter shortcuts are still ours.
  if (event.key.startsWith("Arrow") && event.target.tagName === "SELECT") return

  if (moveRow(step)) event.preventDefault()
})

// "m" files the focused inbox row by driving the row's own read/unread button,
// so the key and the mouse take one path to the server. Rows elsewhere carry no
// such button and the key is inert on them: only the inbox has a read state.
document.addEventListener("keydown", (event) => {
  if (event.key !== "m") return
  if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return
  if (isEditable(event.target)) return
  if (document.querySelector("dialog[open]")) return

  let row = event.target.closest?.("ul.row-list > li")
  let button = row?.querySelector("button[phx-click='toggle-read']")
  if (!button) return

  event.preventDefault()
  keepCursorOn(cursorTarget(row))
  button.click()
})

// Which row the cursor belongs on once the toggle lands. The Unread segment
// holds only unread rows, so the toggle always drops this one and the cursor
// takes its neighbour — the next row, or the previous one at the end of the
// list. Under All the row stays, and so does the cursor.
//
// Nothing is focused here. Moving the cursor ahead of the round trip only
// splits one action into two visible steps; leaving it lets the cursor arrive
// with the row it belongs to.
function cursorTarget(row) {
  if (!document.querySelector("#filter-unread.is-active")) return row.id

  let rows = keynavRows()
  let index = rows.findIndex((line) => line.closest("ul.row-list > li") === row)
  let neighbour = rows[index + 1] || rows[index - 1]

  return neighbour?.closest("ul.row-list > li")?.id
}

// Closing the gap left by the toggled row moves the surviving keyed <li> into
// its place, and moving a node is an implicit remove and re-insert, which blurs
// whatever inside it held focus. So the cursor is placed by id once the patch
// lands — the row is there, just somewhere else in the list.
//
// Nothing announces the end of a patch, hence the observer and the deadline.
// It restores only from <body>, so a click elsewhere during the round trip
// keeps focus, and it stays subscribed until the deadline because a patch that
// moves the row more than once would otherwise strand the cursor again.
function keepCursorOn(id) {
  if (!id) return

  let observer = new MutationObserver(() => {
    if (document.activeElement !== document.body) return

    let line = document.querySelector(`#${CSS.escape(id)} > .row-line`)
    if (!line) return

    line.focus()
    line.scrollIntoView({block: "nearest"})
  })

  observer.observe(document.body, {childList: true, subtree: true})
  setTimeout(() => observer.disconnect(), PATCH_MS)
}

// A closed <details> stays closed when a fragment link points inside it, so
// open the option the hash names and bring it into view. Runs on every full
// load and hash change here; the LiveView AnchorExpand hook reuses it to cover
// live navigation, where no page load fires.
export function expandHashTarget() {
  let hash = window.location.hash
  if (!hash) return

  let target = document.getElementById(decodeURIComponent(hash.slice(1)))
  if (!target) return

  let details = target.tagName === "DETAILS" ? target : target.querySelector("details")
  if (!details) return

  details.open = true
  requestAnimationFrame(() => target.scrollIntoView({block: "start"}))
}

expandHashTarget()
window.addEventListener("hashchange", expandHashTarget)

// Auto-submit the lens form on dropdown change so the channel applies without
// clicking "Set". The form's phx-change is present in the markup either way but
// inert without a socket, so liveSocket — not the attribute — is what says
// whether LiveView is already handling the change.
document.addEventListener("change", (event) => {
  if (window.liveSocket) return
  if (event.target.matches(".lens__select")) event.target.form.requestSubmit()
})
