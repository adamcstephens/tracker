defmodule GitHub.App do
  @moduledoc """
  A GitHub App identity, used to mint short-lived JWTs for app authentication.

  A JWT signed with the app's private key authenticates as the app itself
  (e.g. to create installation access tokens). JWTs are valid for several
  minutes, so they are cached in `GitHub.Auth.Cache` keyed by app id.
  """

  use TypedStruct

  alias GitHub.Auth.Cache

  # GitHub rejects JWTs whose `iat` is in the future; back-date to absorb
  # clock drift between this host and GitHub.
  @clock_drift_sec 60
  @duration_sec 10 * 60

  typedstruct enforce: true do
    field :id, integer()
    field :pem, String.t()
  end

  @doc """
  Returns a signed, cached JWT (RS256) authenticating as the app.
  """
  @spec jwt(t()) :: String.t()
  def jwt(%__MODULE__{id: id, pem: pem}) do
    case Cache.get({:app, id}) do
      {:ok, jwt} ->
        jwt

      :error ->
        now = System.os_time(:second)
        expiration = now - @clock_drift_sec + @duration_sec

        claims = %{
          "iat" => now - @clock_drift_sec,
          "exp" => expiration,
          "iss" => id
        }

        jwk = JOSE.JWK.from_pem(pem)
        jws = JOSE.JWS.from_map(%{"alg" => "RS256", "typ" => "JWT"})

        {_, jwt} =
          jwk
          |> JOSE.JWT.sign(jws, claims)
          |> JOSE.JWS.compact()

        Cache.put({:app, id}, expiration, jwt)
        jwt
    end
  end
end
