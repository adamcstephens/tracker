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

let Hooks = {}

Hooks.UpdateURL = {
  mounted() {
    this.handleEvent("update-url", ({path}) => {
      history.replaceState(history.state, "", path)
    })
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
      if (target && target.tagName === "DETAILS") {
        target.open = true
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

Hooks.LensCookie = {
  mounted() {
    this.handleEvent("set_lens_cookie", ({value, max_age, lens_channel, lens_rev}) => {
      document.cookie = `_tracker_lens=${encodeURIComponent(value)}; path=/; max-age=${max_age}; samesite=lax`
      sessionStorage.setItem("lens_channel", lens_channel)
      if (lens_rev) {
        sessionStorage.setItem("lens_rev", lens_rev)
      } else {
        sessionStorage.removeItem("lens_rev")
      }
    })
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => {
    let params = {_csrf_token: csrfToken}
    let channel = sessionStorage.getItem("lens_channel")
    let rev = sessionStorage.getItem("lens_rev")
    if (channel) params._lens_channel = channel
    if (rev) params._lens_rev = rev
    return params
  },
  hooks: Hooks
})

// Focus the header search input when "/" is pressed outside of an editable element.
document.addEventListener("keydown", (event) => {
  if (event.key !== "/") return
  if (event.ctrlKey || event.metaKey || event.altKey) return

  let target = event.target
  if (target && (target.isContentEditable ||
      target.tagName === "INPUT" ||
      target.tagName === "TEXTAREA" ||
      target.tagName === "SELECT")) {
    return
  }

  let input = document.getElementById("page-search-input")
  if (!input) return

  event.preventDefault()
  input.focus()
  input.select()
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

