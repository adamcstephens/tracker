defmodule TrackerWeb.Plug.BearerAuth do
  @moduledoc """
  Authenticates a request via `Authorization: Bearer <jwt>` and assigns
  `:current_user` and `:current_user_token`. Rejects with 401 JSON on any failure.

  Options:

    * `:purpose` — required JWT purpose claim. Defaults to `"api"`.
  """
  @behaviour Plug

  import Plug.Conn

  alias AshAuthentication.Jwt
  alias Tracker.Accounts.User

  @impl Plug
  def init(opts), do: Keyword.put_new(opts, :purpose, "api")

  @impl Plug
  def call(conn, opts) do
    purpose = Keyword.fetch!(opts, :purpose)

    with {:ok, jwt} <- extract_bearer(conn),
         {:ok, claims, _resource} <- verify(jwt),
         :ok <- check_purpose(claims, purpose),
         {:ok, user} <- load_user(claims) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_user_token, claims["jti"])
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

  defp load_user(%{"sub" => subject}) do
    case Ash.read_one(
           User
           |> Ash.Query.for_read(:get_by_subject, %{subject: subject}),
           authorize?: false
         ) do
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
