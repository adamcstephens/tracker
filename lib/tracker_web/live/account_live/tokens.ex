defmodule TrackerWeb.AccountLive.Tokens do
  use TrackerWeb, :live_view

  alias Tracker.Accounts.{Token, User}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user
    admin? = User.has_role?(current_user, :admin)

    {:ok,
     socket
     |> assign(:page_title, "API tokens")
     |> assign(:admin?, admin?)
     |> assign(:current_user, current_user)
     |> assign(:viewing_user, current_user)
     |> assign(:service_accounts, load_service_accounts(admin?, current_user))
     |> assign(:fresh_token, nil)
     |> assign(:form, new_form())
     |> load_tokens()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.header>
      API tokens
      <:subtitle :if={@viewing_user.id == @current_user.id}>
        Tokens you have issued for yourself.
      </:subtitle>
      <:subtitle :if={@viewing_user.id != @current_user.id}>
        Tokens for service account <strong>{@viewing_user.github_username}</strong>.
      </:subtitle>
    </.header>

    <div :if={@admin? and @service_accounts != []} style="margin-bottom: 1rem;">
      <form phx-change="select_user">
        <label for="account-select">Viewing tokens for</label>
        <select id="account-select" name="user_id">
          <option value={@current_user.id} selected={@viewing_user.id == @current_user.id}>
            {@current_user.github_username} (you)
          </option>
          <option
            :for={u <- @service_accounts}
            value={u.id}
            selected={@viewing_user.id == u.id}
          >
            {u.github_username}
          </option>
        </select>
      </form>
    </div>

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
      <.input
        field={@form[:expires_in_days]}
        type="number"
        label="Expires in (days)"
        min="1"
      />
      <:actions>
        <.button type="submit">Issue token</.button>
      </:actions>
    </.simple_form>

    <h2>Existing tokens</h2>

    <p :if={@tokens == []}>No tokens.</p>

    <.table :if={@tokens != []} id="tokens" rows={@tokens}>
      <:col :let={t} label="Label">{label_for(t)}</:col>
      <:col :let={t} label="Status">{status_for(t)}</:col>
      <:col :let={t} label="Created">{Calendar.strftime(t.inserted_at, "%Y-%m-%d %H:%M UTC")}</:col>
      <:col :let={t} label="Expires">{Calendar.strftime(t.expires_at, "%Y-%m-%d %H:%M UTC")}</:col>
      <:col :let={t} label="JTI"><code>{t.jti}</code></:col>
      <:action :let={t}>
        <button
          :if={t.purpose == "api"}
          type="button"
          phx-click="revoke"
          phx-value-jti={t.jti}
          data-confirm="Revoke this token?"
        >
          Revoke
        </button>
      </:action>
    </.table>
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

    case User.issue_api_token(socket.assigns.viewing_user.id, args,
           actor: socket.assigns.current_user
         ) do
      {:ok, %{token: jwt}} ->
        {:noreply,
         socket
         |> assign(:fresh_token, jwt)
         |> assign(:form, new_form())
         |> put_flash(:info, "Token issued.")
         |> load_tokens()}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply, put_flash(socket, :error, "Not allowed to issue a token for that user.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(error)}")}
    end
  end

  def handle_event("revoke", %{"jti" => jti}, socket) do
    actor = socket.assigns.current_user

    result =
      if socket.assigns.viewing_user.id == actor.id do
        Token.revoke_own_token(jti, actor: actor)
      else
        Token.revoke_token_admin(jti, actor: actor)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Token revoked.")
         |> load_tokens()}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply, put_flash(socket, :error, "Not allowed to revoke that token.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(error)}")}
    end
  end

  def handle_event("select_user", %{"user_id" => user_id}, socket) do
    target =
      if user_id == socket.assigns.current_user.id do
        socket.assigns.current_user
      else
        Enum.find(socket.assigns.service_accounts, &(&1.id == user_id)) ||
          socket.assigns.current_user
      end

    {:noreply,
     socket
     |> assign(:viewing_user, target)
     |> assign(:fresh_token, nil)
     |> load_tokens()}
  end

  def handle_event("dismiss_fresh_token", _params, socket) do
    {:noreply, assign(socket, :fresh_token, nil)}
  end

  defp load_tokens(socket) do
    subject = AshAuthentication.user_to_subject(socket.assigns.viewing_user)

    tokens =
      Token.list_api_tokens_for_subject!(subject, actor: socket.assigns.current_user)

    assign(socket, :tokens, tokens)
  end

  defp load_service_accounts(true, actor), do: User.list_service_accounts!(actor: actor)
  defp load_service_accounts(false, _actor), do: []

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

  defp label_for(%{extra_data: %{"label" => label}}) when is_binary(label) and label != "",
    do: label

  defp label_for(_), do: "—"

  defp status_for(%{purpose: "api"}), do: "active"
  defp status_for(%{purpose: "revocation"}), do: "revoked"
  defp status_for(_), do: "—"
end
