defmodule Tracker.Secrets do
  use AshAuthentication.Secret

  def secret_for([:authentication, :tokens, :signing_secret], Tracker.Accounts.User, _opts) do
    Application.fetch_env(:tracker, :token_signing_secret)
  end

  def secret_for([:authentication, :strategies, :github, :client_id], Tracker.Accounts.User, _) do
    get_github_config(:client_id)
  end

  def secret_for(
        [:authentication, :strategies, :github, :client_secret],
        Tracker.Accounts.User,
        _
      ) do
    get_github_config(:client_secret)
  end

  def secret_for([:authentication, :strategies, :github, :redirect_uri], Tracker.Accounts.User, _) do
    get_github_config(:redirect_uri)
  end

  defp get_github_config(key) do
    Application.get_env(:tracker, :github, [])
    |> Keyword.fetch!(key)
  end
end
