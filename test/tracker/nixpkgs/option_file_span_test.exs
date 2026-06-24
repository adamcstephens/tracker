defmodule Tracker.Nixpkgs.OptionFileSpanTest do
  use Tracker.DataCase, async: true

  alias Tracker.Fixtures
  alias Tracker.Nixpkgs.{ChannelRevision, File, Option, OptionFileSpan, OptionSpan, SpanEngine}

  defp revision!(channel, hash, released_at, previous \\ nil) do
    ChannelRevision.create!(%{
      channel_id: channel.id,
      revision: hash,
      released_at: released_at,
      previous_channel_revision_id: previous && previous.id
    })
  end

  defp option_ids, do: Option.id_map!() |> Map.new(&{&1.name, &1.id})
  defp file_id(path), do: File.get_by_path!(path).id

  describe "reconstruction against source" do
    test "the spans reconstruct exactly the loaded option↔file membership" do
      channel = Fixtures.channel!("nixos-unstable")
      rev = revision!(channel, "filerec1", ~U[2026-04-01 10:00:00Z])

      source = %{
        "services.a" => %{"type" => "bool", "declarations" => ["a.nix", "shared.nix"]},
        "services.b" => %{"type" => "bool", "declarations" => ["shared.nix"]},
        # An option with no declarations contributes no membership spans.
        "services.c" => %{"type" => "bool"}
      }

      Fixtures.load_options(source, rev)

      oid = option_ids()

      expected = %{
        [oid["services.a"], file_id("a.nix")] => %{},
        [oid["services.a"], file_id("shared.nix")] => %{},
        [oid["services.b"], file_id("shared.nix")] => %{}
      }

      assert SpanEngine.verify(OptionFileSpan.spec(), channel.id, rev.released_at, expected) ==
               :ok
    end
  end

  describe "a file move closes the old span and opens a new one" do
    test "membership tracks the declaring file, keyed by file identity (path)" do
      channel = Fixtures.channel!("nixos-unstable")
      rev1 = revision!(channel, "filemv01", ~U[2026-04-01 10:00:00Z])
      rev2 = revision!(channel, "filemv02", ~U[2026-04-02 10:00:00Z], rev1)

      Fixtures.load_options(%{"services.a" => %{"declarations" => ["old/path.nix"]}}, rev1)
      # Same option, declaration moved to a new path — a new file identity.
      Fixtures.load_options(%{"services.a" => %{"declarations" => ["new/path.nix"]}}, rev2)

      oid = option_ids()

      assert SpanEngine.verify(OptionFileSpan.spec(), channel.id, rev1.released_at, %{
               [oid["services.a"], file_id("old/path.nix")] => %{}
             }) == :ok

      assert SpanEngine.verify(OptionFileSpan.spec(), channel.id, rev2.released_at, %{
               [oid["services.a"], file_id("new/path.nix")] => %{}
             }) == :ok
    end
  end

  describe "file-membership span ⊆ option existence span invariant" do
    test "removing an option closes its membership spans too" do
      channel = Fixtures.channel!("nixos-unstable")
      rev1 = revision!(channel, "fileinv1", ~U[2026-04-01 10:00:00Z])
      rev2 = revision!(channel, "fileinv2", ~U[2026-04-02 10:00:00Z], rev1)

      Fixtures.load_options(
        %{
          "services.a" => %{"declarations" => ["a.nix"]},
          "services.b" => %{"declarations" => ["b.nix"]}
        },
        rev1
      )

      # services.b drops out of the (complete) revision entirely.
      Fixtures.load_options(%{"services.a" => %{"declarations" => ["a.nix"]}}, rev2)

      # Every open membership span's option_id is backed by an open option span.
      option_keys =
        MapSet.new(OptionSpan.at!(channel.id, rev2.released_at), & &1.option_id)

      membership_option_ids =
        MapSet.new(OptionFileSpan.at!(channel.id, rev2.released_at), & &1.option_id)

      assert MapSet.subset?(membership_option_ids, option_keys)

      oid = option_ids()
      refute MapSet.member?(membership_option_ids, oid["services.b"])
    end
  end
end
