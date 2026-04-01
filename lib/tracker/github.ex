defmodule Tracker.GitHub do
  @moduledoc """
  GitHub API authentication helpers.
  """

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
  Returns the number of seconds until the rate limit resets.

  Falls back to 60 seconds if the rate limit endpoint can't be reached.
  """
  def seconds_until_reset(token) do
    case GitHub.RateLimit.get(auth: token) do
      {:ok, %{rate: %{reset: reset}}} ->
        max(reset - System.os_time(:second), 1)

      _ ->
        60
    end
  end

  defp github_config!(key) do
    Application.fetch_env!(:tracker, :github) |> Keyword.fetch!(key)
  end
end
