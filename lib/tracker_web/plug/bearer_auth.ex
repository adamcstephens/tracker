defmodule TrackerWeb.Plug.BearerAuth do
  @moduledoc """
  Authenticates a request via `Authorization: Bearer <jwt>` and assigns
  `:current_user` and `:current_user_token`. Rejects with 401 JSON on any failure.

  Revocation is checked against the `api_tokens` table — independent of
  AshAuthentication's session-token table, so logging out does not affect
  long-lived API tokens.

  Options:

    * `:purpose` — required JWT purpose claim. Defaults to `"api"`.
  """
  @behaviour Plug

  import Plug.Conn

  alias AshAuthentication.Jwt
  alias Tracker.Accounts.{ApiToken, User}

  @impl Plug
  def init(opts), do: Keyword.put_new(opts, :purpose, "api")

  @impl Plug
  def call(conn, opts) do
    purpose = Keyword.fetch!(opts, :purpose)

    with {:ok, jwt} <- extract_bearer(conn),
         {:ok, claims, _resource} <- verify(jwt),
         :ok <- check_purpose(claims, purpose),
         {:ok, token_row} <- load_token(claims["jti"]),
         :ok <- check_not_revoked(token_row),
         {:ok, user} <- load_user(token_row.subject_user_id) do
      ApiToken.touch_last_used_at(token_row.jti)

      conn
      |> assign(:current_user, user)
      |> assign(:current_user_token, token_row.jti)
    else
      {:error, reason} -> deny(conn, reason)
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> jwt] when byte_size(jwt) > 0 -> {:ok, jwt}
      [] -> {:error, :missing_bearer_token}
      _ -> {:error, :invalid_authorization_header}
    end
  end

  defp verify(jwt) do
    case Jwt.verify(jwt, :tracker) do
      {:ok, claims, resource} -> {:ok, claims, resource}
      :error -> {:error, :invalid_token}
    end
  end

  defp check_purpose(%{"purpose" => purpose}, purpose), do: :ok
  defp check_purpose(_claims, _expected), do: {:error, :invalid_purpose}

  defp load_token(jti) do
    case ApiToken.get_by_jti(jti) do
      {:ok, %ApiToken{} = row} -> {:ok, row}
      _ -> {:error, :invalid_token}
    end
  end

  defp check_not_revoked(%ApiToken{revoked_at: nil}), do: :ok
  defp check_not_revoked(%ApiToken{}), do: {:error, :revoked}

  defp load_user(user_id) do
    case Ash.get(User, user_id, authorize?: false) do
      {:ok, %User{} = user} -> {:ok, user}
      _ -> {:error, :invalid_token}
    end
  end

  defp deny(conn, reason) do
    body = Jason.encode!(%{error: to_string(reason)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
