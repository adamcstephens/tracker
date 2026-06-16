defmodule GitHub.Apps do
  @moduledoc """
  GitHub Apps endpoints.
  """

  alias GitHub.Client

  defmodule InstallationToken do
    @moduledoc "An installation access token."
    use TypedStruct

    typedstruct do
      field :token, String.t()
      field :expires_at, String.t()
    end
  end

  @doc """
  Creates an installation access token for the given installation.

  Requires app (JWT) authentication via `auth: GitHub.app()`.
  """
  @spec create_installation_access_token(integer(), map(), keyword()) ::
          {:ok, InstallationToken.t()} | {:error, GitHub.Error.t()}
  def create_installation_access_token(installation_id, body, opts \\ []) do
    client_opts = Keyword.put(Keyword.take(opts, [:auth, :plug, :s3_cache, :server]), :body, body)

    with {:ok, json} <-
           Client.post("/app/installations/#{installation_id}/access_tokens", client_opts) do
      {:ok, %InstallationToken{token: json["token"], expires_at: json["expires_at"]}}
    end
  end
end
