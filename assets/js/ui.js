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

// Auto-submit the lens form on dropdown change so the channel applies without
// clicking "Set". The form's phx-change is present in the markup either way but
// inert without a socket, so liveSocket — not the attribute — is what says
// whether LiveView is already handling the change.
document.addEventListener("change", (event) => {
  if (window.liveSocket) return
  if (event.target.matches(".lens__select")) event.target.form.requestSubmit()
})
