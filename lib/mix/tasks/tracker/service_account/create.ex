defmodule Mix.Tasks.Tracker.ServiceAccount.Create do
  @shortdoc "Creates a service-account user"
  @moduledoc """
  Creates a Tracker service-account user with the given roles.

  ## Usage

      mix tracker.service_account.create --actor <admin-username> --name <name> --roles <comma-separated>

  ## Options

    * `--actor` - github username of an admin user (required)
    * `--name`  - service account name; stored as `service:<name>` (required)
    * `--roles` - comma-separated list of roles, e.g. `user,maintainer` (required)
  """

  use Mix.Task

  alias Mix.Tasks.Tracker.ApiToken.Support
  alias Tracker.Accounts.User

  @switches [actor: :string, name: :string, roles: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    opts = parse!(args)
    actor = Support.fetch_user_by_github_username!(opts[:actor])
    roles = parse_roles(opts[:roles])

    case User.create_service_account(opts[:name], roles, actor: actor) do
      {:ok, user} ->
        Mix.shell().info("Created service account #{user.github_username} (#{user.id})")

      {:error, error} ->
        Mix.raise("Failed to create service account: #{Exception.message(error)}")
    end
  end

  @doc false
  def parse!(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    for key <- [:actor, :name, :roles] do
      opts[key] || Mix.raise("missing required --#{key}")
    end

    opts
  end

  defp parse_roles(roles) do
    roles
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_existing_atom/1)
  end
end
