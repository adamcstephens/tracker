defmodule TrackerWeb.AccountLive.Settings do
  use TrackerWeb, :live_view

  alias Tracker.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Account settings")
     |> assign(:live_ui, socket.assigns.current_user.live_ui)
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
end
