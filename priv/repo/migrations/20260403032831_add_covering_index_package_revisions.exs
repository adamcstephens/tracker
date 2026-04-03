defmodule Tracker.Repo.Migrations.AddCoveringIndexPackageRevisions do
  use Ecto.Migration

  def change do
    create index(:package_revisions, [:package_id],
             include: [:id, :version, :channel_revision_id],
             name: :idx_pkg_rev_covering
           )
  end
end
