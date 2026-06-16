defmodule GitHub do
  @moduledoc """
  Entry point for the custom GitHub REST API client.

  Operations live in resource modules (`GitHub.Apps`, `GitHub.Repos`,
  `GitHub.Actions`, `GitHub.Pulls`, `GitHub.RateLimit`) backed by
  `GitHub.Client`. This module exposes app-level authentication helpers.
  """

  alias GitHub.App

  @doc """
  Builds the configured GitHub App identity from `config :tracker, :github`.

  Requires `:app_id` and `:app_private_key` to be set.
  """
  @spec app() :: App.t()
  def app do
    config = Application.fetch_env!(:tracker, :github)

    %App{
      id: Keyword.fetch!(config, :app_id),
      pem: Keyword.fetch!(config, :app_private_key)
    }
  end
end
