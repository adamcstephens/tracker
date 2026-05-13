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
