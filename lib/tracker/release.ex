defmodule Tracker.Release do
  @moduledoc """
  Release-time tasks, invoked as `bin/tracker eval 'Tracker.Release.migrate()'`.

  Mix is not available in a release, so migrations run through
  `Ecto.Migrator` against the migrations shipped in `priv`.
  """

  @app :tracker

  @spec migrate() :: :ok
  def migrate do
    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @spec repos() :: [Ecto.Repo.t()]
  def repos do
    Application.load(@app)
    Application.fetch_env!(@app, :ecto_repos)
  end
end
