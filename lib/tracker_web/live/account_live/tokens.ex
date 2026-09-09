defmodule TrackerWeb.AccountLive.Tokens do
  use TrackerWeb, :live_view

  alias Tracker.Accounts.ApiToken
  alias TrackerWeb.RowList
  alias TrackerWeb.SectionHeader
  alias TrackerWeb.Time

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "API tokens")
     |> assign(:current_user, current_user)
     |> assign(:fresh_token, nil)
     |> assign(:form, new_form())
     |> load_tokens()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.header>
      Your API tokens
    </.header>

    <div :if={@fresh_token} id="fresh-token" style="margin-bottom: 1rem;">
      <p>
        <strong>Copy this token now — it will not be shown again.</strong>
      </p>
      <pre id="fresh-token-value" style="user-select: all;">{@fresh_token}</pre>
      <button type="button" phx-click="dismiss_fresh_token">Dismiss</button>
    </div>

    <h2>Issue a new token</h2>

    <.simple_form for={@form} id="issue-form" phx-submit="issue">
      <.input field={@form[:label]} type="text" label="Label (optional)" />
      <.input field={@form[:expires_in_days]} type="number" label="Expires in (days)" min="1" />
      <:actions>
        <.button type="submit">Issue token</.button>
      </:actions>
    </.simple_form>

    <SectionHeader.section_header title="Existing tokens" count={length(@tokens)} />

    <p :if={@tokens == []}>No tokens.</p>

    <RowList.row_list :if={@tokens != []} id="tokens" stacked>
      <RowList.row :for={t <- @tokens} id={"token-#{t.jti}"} mode={:plain}>
        <:label>{label_for(t)}</:label>
        <:sublabel>
          <code>{t.jti}</code>
          <span>issued {format_datetime(t.inserted_at, @time_zone)}</span>
          <span>expires {format_datetime(t.expires_at, @time_zone)}</span>
        </:sublabel>
        <:meta>{status_for(t)}</:meta>
        <:actions>
          <button
            :if={is_nil(t.revoked_at)}
            type="button"
            phx-click="revoke"
            phx-value-jti={t.jti}
            data-confirm="Revoke this token?"
          >
            Revoke
          </button>
        </:actions>
      </RowList.row>
    </RowList.row_list>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("issue", %{"token" => params}, socket) do
    expires_in = parse_expires_in(params["expires_in_days"])
    label = blank_to_nil(params["label"])

    args =
      %{}
      |> maybe_put(:expires_in, expires_in)
      |> maybe_put(:label, label)

    case ApiToken.issue(socket.assigns.current_user.id, args, actor: socket.assigns.current_user) do
      {:ok, %{token: jwt}} ->
        {:noreply,
         socket
         |> assign(:fresh_token, jwt)
         |> assign(:form, new_form())
         |> put_flash(:info, "Token issued.")
         |> load_tokens()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(error)}")}
    end
  end

  def handle_event("revoke", %{"jti" => jti}, socket) do
    case ApiToken.revoke(jti, actor: socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Token revoked.")
         |> load_tokens()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(error)}")}
    end
  end

  def handle_event("dismiss_fresh_token", _params, socket) do
    {:noreply, assign(socket, :fresh_token, nil)}
  end

  defp load_tokens(socket) do
    tokens = ApiToken.list_for_actor!(actor: socket.assigns.current_user)
    assign(socket, :tokens, tokens)
  end

  defp new_form do
    to_form(%{"label" => "", "expires_in_days" => "365"}, as: :token)
  end

  defp parse_expires_in(nil), do: nil
  defp parse_expires_in(""), do: nil

  defp parse_expires_in(value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} when days > 0 -> days * 24 * 60 * 60
      _ -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp label_for(%{label: label}) when is_binary(label) and label != "", do: label
  defp label_for(_), do: "—"

  defp status_for(%{revoked_at: nil}), do: "active"
  defp status_for(%{revoked_at: %DateTime{}}), do: "revoked"

  defp format_datetime(dt, time_zone), do: Time.format_datetime(dt, time_zone)
end
