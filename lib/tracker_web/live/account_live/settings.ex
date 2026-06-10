defmodule TrackerWeb.AccountLive.Settings do
  use TrackerWeb, :live_view

  alias Tracker.Accounts.User
  alias TrackerWeb.FeedLink

  @impl true
  def mount(_params, _session, socket) do
    user = FeedLink.ensure_token(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:page_title, "Account settings")
     |> assign(:live_ui, user.live_ui)
     |> assign(:feed_path, FeedLink.path(user))
     |> assign(:revealed_feed_url, nil)
     |> assign(:saved?, false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Account settings
    </.header>

    <p :if={@saved?} class="flash flash--info">Saved.</p>

    <form id="settings-form" phx-submit="save">
      <h2>Interactive UI</h2>
      <p>
        When enabled, pages use LiveView for in-place updates and a faster
        feel. When disabled, pages render as plain HTML with no JavaScript
        and no WebSocket — navigation does full page reloads. The
        /account/tokens page always uses LiveView regardless of this
        preference.
      </p>

      <label>
        <input type="hidden" name="settings[live_ui]" value="false" />
        <input
          type="checkbox"
          name="settings[live_ui]"
          value="true"
          checked={@live_ui}
        /> Use LiveView
      </label>

      <div style="margin-top: 1rem;">
        <button type="submit">Save</button>
      </div>
    </form>

    <section :if={@feed_path} id="notifications-feed">
      <h2>Notifications feed</h2>
      <p>
        A private Atom feed of your notifications. Click the icon to copy its
        URL, or right-click to copy the link. Keep it secret — anyone with the
        URL can read your notifications. Regenerating it revokes the old URL.
      </p>

      <div class="settings-feed">
        <a
          id="feed-link"
          class="settings-feed__copy"
          href={@feed_path}
          phx-hook="CopyLink"
          title="Copy your private Atom feed URL"
          aria-label="Copy your private Atom feed URL"
        >
          <img src="/images/feed.svg" alt="" width="20" height="20" />
        </a>
        <button
          id="regenerate-feed-token"
          type="button"
          phx-click="regenerate-feed-token"
          data-confirm="Regenerate your feed URL? The current URL will stop working in any feed reader using it."
        >
          Regenerate
        </button>
      </div>

      <div :if={@revealed_feed_url} class="settings-feed__revealed">
        <p>Your new feed URL — copy it into your reader now:</p>
        <div class="settings-feed">
          <input id="feed-url" type="text" readonly value={@revealed_feed_url} />
          <a
            id="copy-feed-url"
            class="settings-feed__copy"
            href={@revealed_feed_url}
            phx-hook="CopyLink"
            title="Copy your private Atom feed URL"
            aria-label="Copy your private Atom feed URL"
          >
            <img src="/images/feed.svg" alt="" width="20" height="20" />
          </a>
        </div>
      </div>
    </section>
    """
  end

  @impl true
  def handle_event("save", %{"settings" => %{"live_ui" => live_ui}}, socket) do
    live_ui? = live_ui == "true"
    user = socket.assigns.current_user

    case User.set_live_ui(user, %{live_ui: live_ui?}, actor: user) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:current_user, updated)
         |> assign(:live_ui, updated.live_ui)
         |> assign(:saved?, true)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(error)}")}
    end
  end

  def handle_event("regenerate-feed-token", _params, socket) do
    user = socket.assigns.current_user
    {:ok, updated} = User.rotate_feed_token(user, actor: user)
    new_path = FeedLink.path(updated)

    {:noreply,
     socket
     |> assign(:current_user, updated)
     |> assign(:feed_path, new_path)
     |> assign(:revealed_feed_url, new_path)
     |> put_flash(:info, "Feed URL regenerated. The previous URL no longer works.")}
  end
end
