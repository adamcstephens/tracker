defmodule Tracker.Nixpkgs.MetadataSnapshot do
  use TypedStruct

  typedstruct enforce: true do
    field :package_ids, map()
    field :maintainers, map()
    field :teams, map()
    field :joins, map()
  end
end
