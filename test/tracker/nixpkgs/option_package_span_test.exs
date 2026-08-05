defmodule Tracker.Nixpkgs.OptionPackageSpanTest do
  use Tracker.DataCase, async: true

  alias Tracker.Fixtures
  alias Tracker.Nixpkgs.{ChannelRevision, OptionPackageSpan, SpanEngine}

  defp revision!(channel, hash, released_at, previous \\ nil) do
    ChannelRevision.create!(%{
      channel_id: channel.id,
      revision: hash,
      released_at: released_at,
      previous_channel_revision_id: previous && previous.id
    })
  end

  describe "reconstruction against source" do
    test "the spans reconstruct exactly the loaded option↔package links" do
      channel = Fixtures.channel!()
      rev = revision!(channel, "pkglink1", ~U[2026-04-01 10:00:00Z])

      option_a = Fixtures.option!("services.a.package")
      option_b = Fixtures.option!("services.b.package")
      pkg_a = Fixtures.package!("a")
      pkg_b = Fixtures.package!("b")

      Fixtures.apply_option_packages!(rev, [
        {option_a, pkg_a},
        {option_a, pkg_b},
        {option_b, pkg_b}
      ])

      expected = %{
        [option_a.id, pkg_a.id] => %{},
        [option_a.id, pkg_b.id] => %{},
        [option_b.id, pkg_b.id] => %{}
      }

      assert SpanEngine.verify(OptionPackageSpan.spec(), channel.id, rev.released_at, expected) ==
               :ok
    end
  end

  describe "repointing an option at a different package" do
    test "closes the stale link and opens the new one" do
      channel = Fixtures.channel!()
      rev1 = revision!(channel, "pkgmove1", ~U[2026-04-01 10:00:00Z])
      rev2 = revision!(channel, "pkgmove2", ~U[2026-04-02 10:00:00Z], rev1)

      option = Fixtures.option!("services.victorialogs.package")
      old_pkg = Fixtures.package!("victoriametrics")
      new_pkg = Fixtures.package!("victorialogs")

      Fixtures.apply_option_packages!(rev1, [{option, old_pkg}])
      Fixtures.apply_option_packages!(rev2, [{option, new_pkg}])

      assert SpanEngine.verify(OptionPackageSpan.spec(), channel.id, rev1.released_at, %{
               [option.id, old_pkg.id] => %{}
             }) == :ok

      assert SpanEngine.verify(OptionPackageSpan.spec(), channel.id, rev2.released_at, %{
               [option.id, new_pkg.id] => %{}
             }) == :ok
    end
  end

  describe "packages_for_options_at" do
    test "returns only the links valid at the revision, with the package loaded" do
      channel = Fixtures.channel!()
      rev1 = revision!(channel, "pkgread1", ~U[2026-04-01 10:00:00Z])
      rev2 = revision!(channel, "pkgread2", ~U[2026-04-02 10:00:00Z], rev1)

      option = Fixtures.option!("services.hello.package")
      old_pkg = Fixtures.package!("hello-old")
      new_pkg = Fixtures.package!("hello-new")

      Fixtures.apply_option_packages!(rev1, [{option, old_pkg}])
      Fixtures.apply_option_packages!(rev2, [{option, new_pkg}])

      assert [span] =
               OptionPackageSpan.packages_for_options_at!(
                 channel.id,
                 rev2.released_at,
                 [option.id]
               )

      assert span.package.attribute == "hello-new"
    end
  end

  describe "open_for_packages" do
    test "returns options currently linked to the package, across channels" do
      channel = Fixtures.channel!()
      rev1 = revision!(channel, "pkgopen1", ~U[2026-04-01 10:00:00Z])
      rev2 = revision!(channel, "pkgopen2", ~U[2026-04-02 10:00:00Z], rev1)

      package = Fixtures.package!("victoriametrics")
      stale_option = Fixtures.option!("services.victorialogs.package")
      live_option = Fixtures.option!("services.victoriametrics.package")

      Fixtures.apply_option_packages!(rev1, [
        {stale_option, package},
        {live_option, package}
      ])

      # services.victorialogs repoints away; only the live link stays open.
      Fixtures.apply_option_packages!(rev2, [{live_option, package}])

      assert [span] = OptionPackageSpan.open_for_packages!([package.id])
      assert span.option.name == "services.victoriametrics.package"
    end
  end
end
