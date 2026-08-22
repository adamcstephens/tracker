// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
// Socket-free behaviour, shared with the non-interactive ui.js bundle.
import "./ui.js"

let Hooks = {}

Hooks.UpdateURL = {
  mounted() {
    this.handleEvent("update-url", ({path}) => {
      history.replaceState(history.state, "", path)
      // A fresh search re-renders results in place (no navigation), so reset
      // the viewport to the top the way a full page load would. (trk-278)
      window.scrollTo(0, 0)
    })
  }
}

Hooks.PageAnchor = {
  mounted() {
    this.page = this.el.dataset.page
  },
  updated() {
    if (this.el.dataset.page === this.page) return
    this.page = this.el.dataset.page
    let list = document.getElementById(this.el.dataset.anchor)
    if (!list) return
    // A patch keeps the viewport where it was, which strands mobile readers at
    // the end of the new page; the no-JS path gets this from the URL fragment.
    requestAnimationFrame(() => list.scrollIntoView({block: "start"}))
  }
}

Hooks.AnchorExpand = {
  mounted() {
    this.expandAfterRender()
    this._onHashChange = () => this.expandAfterRender()
    window.addEventListener("hashchange", this._onHashChange)
  },
  updated() {
    this.expandAfterRender()
  },
  destroyed() {
    window.removeEventListener("hashchange", this._onHashChange)
  },
  expandAfterRender() {
    requestAnimationFrame(() => {
      let hash = window.location.hash
      if (!hash) return
      let target = document.getElementById(decodeURIComponent(hash.slice(1)))
      if (!target) return
      let details = target.tagName === "DETAILS" ? target : target.querySelector("details")
      if (details) {
        details.open = true
        target.scrollIntoView({behavior: "smooth", block: "start"})
      }
    })
  }
}

Hooks.ChangeTabs = {
  mounted() { this.sync() },
  updated() { this.sync() },
  sync() {
    const radios = [...this.el.querySelectorAll('input[type="radio"]')]
    const current = radios.find(r => r.checked)
    if (current && !current.disabled) return
    const fallback = radios.find(r => !r.disabled)
    if (fallback) fallback.checked = true
  }
}

// Records the lens the page rendered as the restoration preference.
Hooks.LensCookie = {
  mounted() { this.write() },
  updated() { this.write() },
  write() {
    const value = this.el.dataset.lens
    if (!value) return
    const maxAge = this.el.dataset.lensMaxAge
    document.cookie = `_tracker_lens=${encodeURIComponent(value)}; path=/; max-age=${maxAge}; samesite=lax`
  }
}

// The lens preference, for a LiveView that arrives with no channel param. The
// plug that reads this cookie only runs on a full page load, so mid-session the
// join is the only way the server sees a cookie the client has since rewritten.
let lensPreference = () => {
  const match = document.cookie.match(/(?:^|;\s*)_tracker_lens=([^;]*)/)
  return match ? decodeURIComponent(match[1]) : null
}

// Copy a link's URL to the clipboard instead of navigating to it. The anchor
// stays a real link, so right-click "Copy link address" and non-JS visitors
// still work. `this.el.href` is already resolved to an absolute URL by the
// browser, so feed readers get a usable address regardless of the host.
Hooks.CopyLink = {
  mounted() {
    this.el.addEventListener("click", (event) => {
      event.preventDefault()
      navigator.clipboard.writeText(this.el.href).then(() => {
        this.el.classList.add("is-copied")
        clearTimeout(this._copiedTimer)
        this._copiedTimer = setTimeout(() => this.el.classList.remove("is-copied"), 1500)
      })
    })
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  // A function, so every join re-reads the preference rather than pinning the
  // one that happened to be set when the page loaded.
  params: () => ({_csrf_token: csrfToken, _lens: lensPreference()}),
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

