defmodule Tracker.Nixpkgs.ModuleTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{Channel, ChannelRevision, Module, Option, OptionRevision}

  describe "list/2 channel filtering" do
    setup do
      channel =
        Channel.create!(%{
          name: "nixos-unstable",
          display_name: "nixos-unstable",
          branch: "nixos-unstable",
          status: :active,
          is_stable: false
        })

      cr =
        ChannelRevision
        |> Ash.Changeset.for_create(:create, %{
          channel_id: channel.id,
          revision: "aaa1111",
          released_at: ~U[2025-01-01 00:00:00Z]
        })
        |> Ash.create!()

      mod_in =
        Module
        |> Ash.Changeset.for_create(:bulk_upsert, %{display_name: "services.in-channel"})
        |> Ash.create!()

      mod_out =
        Module
        |> Ash.Changeset.for_create(:bulk_upsert, %{display_name: "services.out-channel"})
        |> Ash.create!()

      # Create option for mod_in with a revision in the channel
      opt_in =
        Option
        |> Ash.Changeset.for_create(:bulk_upsert, %{
          name: "services.in-channel.enable",
          module_id: mod_in.id
        })
        |> Ash.create!()

      OptionRevision
      |> Ash.Changeset.for_create(:load, %{
        option_id: opt_in.id,
        channel_revision_id: cr.id
      })
      |> Ash.create!()

      # Create option for mod_out with NO revision in the channel
      Option
      |> Ash.Changeset.for_create(:bulk_upsert, %{
        name: "services.out-channel.enable",
        module_id: mod_out.id
      })
      |> Ash.create!()

      %{channel: channel, mod_in: mod_in, mod_out: mod_out}
    end

    test "without channel_id returns all modules", %{mod_in: mod_in, mod_out: mod_out} do
      page = Module.list!(nil, nil, page: [count: true])

      names = Enum.map(page.results, & &1.display_name)
      assert mod_in.display_name in names
      assert mod_out.display_name in names
    end

    test "with channel_id returns only modules with options in that channel", %{
      channel: channel,
      mod_in: mod_in,
      mod_out: mod_out
    } do
      page = Module.list!(nil, channel.id, page: [count: true])

      names = Enum.map(page.results, & &1.display_name)
      assert mod_in.display_name in names
      refute mod_out.display_name in names
    end
  end
end
