defmodule Mix.Tasks.Tracker.BackfillFamiliesTest do
  use Tracker.DataCase, async: true

  alias Mix.Tasks.Tracker.BackfillFamilies

  test "backfills package families for existing packages" do
    # Create packages without family data (simulating pre-migration state)
    for attr <- ["python313Packages.numpy", "python312Packages.numpy", "vim"] do
      Ash.create!(Ash.Changeset.for_create(Tracker.Nixpkgs.Package, :create, %{attribute: attr}))
    end

    BackfillFamilies.run([])

    numpy_313 = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "python313Packages.numpy"})
    numpy_312 = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "python312Packages.numpy"})
    vim = Ash.get!(Tracker.Nixpkgs.Package, %{attribute: "vim"})

    # Both numpy packages share the same family
    assert numpy_313.package_family_id != nil
    assert numpy_313.package_family_id == numpy_312.package_family_id
    assert numpy_313.package_set == "python313Packages"
    assert numpy_313.set_version == "3.13"
    assert numpy_312.package_set == "python312Packages"
    assert numpy_312.set_version == "3.12"

    # vim has no family
    assert vim.package_family_id == nil
    assert vim.package_set == nil
  end
end
