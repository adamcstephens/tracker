defmodule Tracker.Nixpkgs.PackageRevision.VersionChange do
  @moduledoc """
  Represents a package revision where the version changed from the previous
  revision in the same channel.
  """

  use TypedStruct

  typedstruct enforce: true do
    field :id, integer()
    field :version, String.t()
    field :package_id, integer()
    field :channel_revision_id, integer()
    field :channel_name, String.t()
    field :revision, String.t()
    field :released_at, DateTime.t()
  end
end
