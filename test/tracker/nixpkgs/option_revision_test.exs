defmodule Tracker.Nixpkgs.OptionRevisionTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{Channel, ChannelRevision, Option, OptionRevision}

  defp create_channel!(name) do
    Channel.create!(%{
      name: name,
      display_name: name,
      status: :active,
      is_stable: false
    })
  end

  defp create_revision!(channel, revision, released_at) do
    Ash.create!(ChannelRevision, %{
      channel_id: channel.id,
      revision: revision,
      released_at: released_at
    })
  end

  defp create_option!(name) do
    id_map = Option.bulk_upsert_all([%{name: name}])
    %{id: Map.fetch!(id_map, name), name: name}
  end

  defp load_option!(name, cr) do
    opt = create_option!(name)

    OptionRevision.load!(%{
      option_id: opt.id,
      channel_revision_id: cr.id,
      description: "desc",
      type: "boolean",
      default: "false",
      example: nil,
      read_only: false
    })
  end

  describe "subgroup_counts/2" do
    test "root groups by top-level segment, counting only deeper options" do
      channel = create_channel!("nixos-unstable")
      cr = create_revision!(channel, "rootgrp1aaa", ~U[2026-04-01 10:00:00Z])

      for name <- [
            "services.nginx.enable",
            "services.openssh.enable",
            "boot.loader.grub.enable",
            "docs"
          ] do
        load_option!(name, cr)
      end

      assert OptionRevision.subgroup_counts(cr.id) == [{"boot", 1}, {"services", 2}]
    end

    test "prefix groups by direct child segment, counting strictly deeper options" do
      channel = create_channel!("nixos-unstable")
      cr = create_revision!(channel, "prefgrp1aaa", ~U[2026-04-01 10:00:00Z])

      for name <- [
            "services.nginx.enable",
            "services.nginx.port",
            "services.openssh.enable",
            "services.docs",
            "programs.vim.enable"
          ] do
        load_option!(name, cr)
      end

      assert OptionRevision.subgroup_counts(cr.id, "services") ==
               [{"services.nginx", 2}, {"services.openssh", 1}]
    end

    test "is scoped to the channel revision" do
      channel = create_channel!("nixos-unstable")
      cr1 = create_revision!(channel, "scopegrp1aa", ~U[2026-04-01 10:00:00Z])
      cr2 = create_revision!(channel, "scopegrp2bb", ~U[2026-04-02 10:00:00Z])

      load_option!("services.nginx.enable", cr1)

      opt = create_option!("services.postgresql.enable")

      OptionRevision.load!(%{
        option_id: opt.id,
        channel_revision_id: cr2.id,
        description: "desc",
        type: "boolean",
        default: "false",
        example: nil,
        read_only: false
      })

      assert OptionRevision.subgroup_counts(cr1.id, "services") == [{"services.nginx", 1}]
    end
  end

  describe "list_direct_by_channel_revision_and_prefix/2" do
    test "empty prefix returns only depth-1 options" do
      channel = create_channel!("nixos-unstable")
      cr = create_revision!(channel, "direct1aaa1", ~U[2026-04-01 10:00:00Z])

      for name <- ["docs", "allowAliases", "services.nginx.enable"] do
        load_option!(name, cr)
      end

      names =
        cr.id
        |> OptionRevision.list_direct_by_channel_revision_and_prefix!("")
        |> Enum.map(& &1.option.name)

      assert names == ["allowAliases", "docs"]
    end

    test "returns the prefix option itself and its direct children, sorted" do
      channel = create_channel!("nixos-unstable")
      cr = create_revision!(channel, "direct2bbb2", ~U[2026-04-01 10:00:00Z])

      for name <- [
            "services.nginx",
            "services.nginx.user",
            "services.nginx.enable",
            "services.nginx.virtualHosts.example.serverName",
            "services.nginxStable.enable"
          ] do
        load_option!(name, cr)
      end

      names =
        cr.id
        |> OptionRevision.list_direct_by_channel_revision_and_prefix!("services.nginx")
        |> Enum.map(& &1.option.name)

      assert names == ["services.nginx", "services.nginx.enable", "services.nginx.user"]
    end
  end

  describe "list_by_channel_revision/3 with a prefix" do
    test "scopes search matches to options under the prefix" do
      channel = create_channel!("nixos-unstable")
      cr = create_revision!(channel, "scoped1aaa11", ~U[2026-04-01 10:00:00Z])

      for name <- [
            "services.nginx.enable",
            "services.openssh.enable",
            "programs.vim.enable"
          ] do
        opt = create_option!(name)

        OptionRevision.load!(%{
          option_id: opt.id,
          channel_revision_id: cr.id,
          description: "desc",
          type: "boolean",
          default: "false",
          example: nil,
          read_only: false
        })
      end

      page = OptionRevision.list_by_channel_revision!(cr.id, "enable", "services")
      names = Enum.map(page.results, & &1.option.name)

      assert "services.nginx.enable" in names
      assert "services.openssh.enable" in names
      refute "programs.vim.enable" in names
    end

    test "an exact prefix match is included" do
      channel = create_channel!("nixos-unstable")
      cr = create_revision!(channel, "scoped2bbb22", ~U[2026-04-01 10:00:00Z])
      opt = create_option!("services.nginx.enable")

      OptionRevision.load!(%{
        option_id: opt.id,
        channel_revision_id: cr.id,
        description: "desc",
        type: "boolean",
        default: "false",
        example: nil,
        read_only: false
      })

      page = OptionRevision.list_by_channel_revision!(cr.id, "", "services.nginx.enable")

      assert Enum.map(page.results, & &1.option.name) == ["services.nginx.enable"]
    end
  end

  describe "metadata_diff/2" do
    test "returns a row per changed metadata field" do
      channel = create_channel!("nixos-unstable")
      cr1 = create_revision!(channel, "metaaaaa111", ~U[2026-04-01 10:00:00Z])
      cr2 = create_revision!(channel, "metabbbb222", ~U[2026-04-02 10:00:00Z])
      opt = create_option!("services.nginx.enable")

      OptionRevision.load!(%{
        option_id: opt.id,
        channel_revision_id: cr1.id,
        description: "Enable nginx.",
        type: "boolean",
        default: "false",
        example: nil,
        read_only: false
      })

      OptionRevision.load!(%{
        option_id: opt.id,
        channel_revision_id: cr2.id,
        description: "Whether to enable the nginx web server.",
        type: "boolean",
        default: "false",
        example: "true",
        read_only: false
      })

      diffs = OptionRevision.metadata_diff(cr1.id, cr2.id)
      assert is_list(diffs)

      assert Enum.any?(diffs, fn d ->
               d.option_name == "services.nginx.enable" and d.field == :description
             end)

      assert Enum.any?(diffs, fn d ->
               d.option_name == "services.nginx.enable" and d.field == :example
             end)

      desc = Enum.find(diffs, fn d -> d.field == :description end)
      assert desc.old == "Enable nginx."
      assert desc.new == "Whether to enable the nginx web server."

      example = Enum.find(diffs, fn d -> d.field == :example end)
      assert example.old == nil
      assert example.new == "true"
    end

    test "omits options whose metadata is unchanged" do
      channel = create_channel!("nixos-unstable")
      cr1 = create_revision!(channel, "samemeta111", ~U[2026-04-01 10:00:00Z])
      cr2 = create_revision!(channel, "samemeta222", ~U[2026-04-02 10:00:00Z])
      opt = create_option!("services.foo.bar")

      attrs = %{
        description: "same",
        type: "string",
        default: "x",
        example: nil,
        read_only: false
      }

      OptionRevision.load!(Map.merge(attrs, %{option_id: opt.id, channel_revision_id: cr1.id}))
      OptionRevision.load!(Map.merge(attrs, %{option_id: opt.id, channel_revision_id: cr2.id}))

      diffs = OptionRevision.metadata_diff(cr1.id, cr2.id)

      refute Enum.any?(diffs, fn d -> d.option_name == "services.foo.bar" end)
    end

    test "omits options that exist in only one revision (those are events, not metadata diffs)" do
      channel = create_channel!("nixos-unstable")
      cr1 = create_revision!(channel, "onlyone1aaa", ~U[2026-04-01 10:00:00Z])
      cr2 = create_revision!(channel, "onlyone2bbb", ~U[2026-04-02 10:00:00Z])
      opt = create_option!("services.added.only")

      OptionRevision.load!(%{
        option_id: opt.id,
        channel_revision_id: cr2.id,
        description: "new",
        type: "boolean",
        default: "false",
        example: nil,
        read_only: false
      })

      diffs = OptionRevision.metadata_diff(cr1.id, cr2.id)

      refute Enum.any?(diffs, fn d -> d.option_name == "services.added.only" end)
    end
  end
end
