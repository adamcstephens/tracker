defmodule Mix.Tasks.Tracker.ApiToken.Issue do
  @shortdoc "Issues an API token for a user"
  @moduledoc """
  Issues an API JWT for the given subject user. The raw JWT is printed
  to stdout once and cannot be retrieved later.

  ## Usage

      mix tracker.api_token.issue --actor <username> --user <id-or-username> [--expires-in <seconds>] [--label <text>]

  ## Options

    * `--actor`       - github username of the actor (required)
    * `--user`        - subject user id or github_username (required)
    * `--expires-in`  - lifetime in seconds (default: 1 year)
    * `--label`       - human-readable label stored in token metadata
  """

  use Mix.Task

  alias Mix.Tasks.Tracker.ApiToken.Support
  alias Tracker.Accounts.User

  @switches [actor: :string, user: :string, expires_in: :integer, label: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    opts = parse!(args)
    actor = Support.fetch_user_by_github_username!(opts[:actor])
    subject = Support.fetch_user!(opts[:user])

    params =
      %{}
      |> maybe_put(:expires_in, opts[:expires_in])
      |> maybe_put(:label, opts[:label])

    case User.issue_api_token(subject.id, params, actor: actor) do
      {:ok, %{token: jwt, jti: jti, expires_at: expires_at}} ->
        Mix.shell().info("jti=#{jti} expires_at=#{DateTime.to_iso8601(expires_at)}")
        Mix.shell().info("This token will not be shown again:")
        Mix.shell().info(jwt)

      {:error, error} ->
        Mix.raise("Failed to issue token: #{Exception.message(error)}")
    end
  end

  @doc false
  def parse!(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    for key <- [:actor, :user] do
      opts[key] || Mix.raise("missing required --#{key}")
    end

    opts
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
