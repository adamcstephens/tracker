defmodule Tracker.Nixpkgs.PackageSpanTest do
  use Tracker.DataCase, async: true

  alias Tracker.Fixtures
  alias Tracker.Nixpkgs.PackageSpan

  describe "for_packages" do
    test "returns all spans for the packages in one channel" do
      chan = Fixtures.channel!()
      other_chan = Fixtures.channel!()
      rev1 = Fixtures.channel_revision!(chan, %{released_at: ~U[2026-06-01 10:00:00Z]})
      rev2 = Fixtures.channel_revision!(chan, %{released_at: ~U[2026-06-15 10:00:00Z]})
      pkg = Fixtures.package!()
      excluded = Fixtures.package!()

      Fixtures.apply_package_revision!(rev1, [{pkg, "1.0"}, {excluded, "1.0"}])
      Fixtures.apply_package_revision!(rev2, [{pkg, "2.0"}])
      Fixtures.apply_package_revision!(Fixtures.channel_revision!(other_chan), [{pkg, "9.9"}])

      spans = PackageSpan.for_packages!(chan.id, [pkg.id])

      assert spans |> Enum.map(& &1.version) |> Enum.sort() == ["1.0", "2.0"]
      assert Enum.all?(spans, &(&1.channel_id == chan.id and &1.package_id == pkg.id))
    end
  end
end
