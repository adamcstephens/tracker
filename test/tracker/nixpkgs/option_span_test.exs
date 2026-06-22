defmodule Tracker.Nixpkgs.OptionSpanTest do
  use Tracker.DataCase, async: true

  alias Tracker.Fixtures
  alias Tracker.Nixpkgs.{ChannelRevision, Option, OptionHistory, OptionSpan, SpanEngine}

  defp revision!(channel, hash, released_at, previous \\ nil) do
    ChannelRevision.create!(%{
      channel_id: channel.id,
      revision: hash,
      released_at: released_at,
      previous_channel_revision_id: previous && previous.id
    })
  end

  defp setup_tree do
    channel = Fixtures.channel!("nixos-unstable")
    rev = revision!(channel, "treeaaaa", ~U[2026-04-01 10:00:00Z])

    opts =
      for name <- [
            "boot",
            "services.nginx",
            "services.nginx.enable",
            "services.nginx.virtualHosts",
            "services.postgresql.enable"
          ],
          into: %{} do
        {name, Fixtures.option!(name)}
      end

    Fixtures.apply_option_revision!(
      rev,
      Enum.map(opts, fn {_name, opt} -> {opt, %{type: "bool"}} end)
    )

    {channel, rev, opts}
  end

  describe "list_direct_by_prefix" do
    test "empty prefix returns depth-1 options only" do
      {channel, rev, _opts} = setup_tree()

      names =
        channel.id
        |> OptionSpan.list_direct_by_prefix!(rev.released_at, "")
        |> Enum.map(& &1.option.name)

      assert names == ["boot"]
    end

    test "prefix returns the option itself plus direct children" do
      {channel, rev, _opts} = setup_tree()

      names =
        channel.id
        |> OptionSpan.list_direct_by_prefix!(rev.released_at, "services.nginx")
        |> Enum.map(& &1.option.name)

      assert names == ["services.nginx", "services.nginx.enable", "services.nginx.virtualHosts"]
    end
  end

  describe "list_by_channel" do
    test "fuzzy-ranks matches and paginates" do
      {channel, rev, _opts} = setup_tree()

      page =
        OptionSpan.list_by_channel!(channel.id, rev.released_at, "nginx", "",
          page: [offset: 0, count: true]
        )

      names = Enum.map(page.results, & &1.option.name)
      assert "services.nginx" in names
      assert "services.nginx.enable" in names
      refute "boot" in names
    end
  end

  describe "reconstruction against source" do
    test "the spans reconstruct exactly the loaded option set" do
      channel = Fixtures.channel!("nixos-unstable")
      rev = revision!(channel, "reconaaa", ~U[2026-04-01 10:00:00Z])

      source = %{
        "services.a" => %{
          "description" => "Option A.",
          "type" => "boolean",
          "default" => %{"text" => "false"},
          "readOnly" => false,
          "loc" => ["services", "a"]
        },
        "services.b" => %{"type" => "str", "relatedPackages" => "pkgs.b"}
      }

      Fixtures.load_options(source, rev)

      ids = Option.id_map!() |> Map.new(&{&1.name, &1.id})

      expected = %{
        [ids["services.a"]] => %{
          description: "Option A.",
          type: "boolean",
          default: "false",
          example: nil,
          read_only: false,
          loc: ["services", "a"],
          related_packages: nil
        },
        [ids["services.b"]] => %{
          description: nil,
          type: "str",
          default: nil,
          example: nil,
          read_only: false,
          loc: nil,
          related_packages: "pkgs.b"
        }
      }

      assert SpanEngine.verify(OptionSpan.spec(), channel.id, rev.released_at, expected) == :ok
    end
  end

  describe "subgroup_counts/3" do
    test "counts options strictly deeper than each subgroup at the prefix" do
      {channel, rev, _opts} = setup_tree()

      assert OptionHistory.subgroup_counts(channel.id, rev.released_at, "services") == [
               {"services.nginx", 2},
               {"services.postgresql", 1}
             ]
    end

    test "root prefix groups by first segment" do
      {channel, rev, _opts} = setup_tree()

      assert OptionHistory.subgroup_counts(channel.id, rev.released_at) == [{"services", 4}]
    end
  end
end
