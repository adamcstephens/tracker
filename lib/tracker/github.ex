defmodule Tracker.GitHub do
  @moduledoc """
  GitHub API authentication helpers.
  """

  @type bucket :: :rest | :graphql

  @doc """
  Returns an installation access token for the configured GitHub App.

  Uses the app credentials to generate a JWT, then exchanges it for
  an installation token scoped to the configured installation.
  """
  def installation_token! do
    app = GitHub.app(:tracker)
    installation_id = github_config!(:installation_id)

    {:ok, %{token: token}} =
      GitHub.Apps.create_installation_access_token(installation_id, %{}, auth: app)

    token
  end

  @doc """
  Returns the number of seconds until the rate limit for `bucket` resets.

  Queries `GET /rate_limit` and reads the reset time for the REST (`core`)
  or GraphQL resource, caches it, and returns the remaining seconds.
  Falls back to 60 seconds if the rate limit endpoint can't be reached.
  """
  @spec seconds_until_reset(String.t(), bucket) :: pos_integer
  def seconds_until_reset(token, bucket) when bucket in [:rest, :graphql] do
    with {:ok, %{resources: resources}} <- GitHub.RateLimit.get(auth: token),
         %{reset: reset} <- resource_for(resources, bucket) do
      Tracker.GitHub.RateLimitCache.set_reset(bucket, reset)
      max(reset - System.os_time(:second), 1)
    else
      _ -> 60
    end
  end

  defp resource_for(%{core: core}, :rest), do: core
  defp resource_for(%{graphql: graphql}, :graphql), do: graphql

  defp github_config!(key) do
    Application.fetch_env!(:tracker, :github) |> Keyword.fetch!(key)
  end
end
