defmodule Tracker.Nixpkgs.OptionTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{
    Change,
    ChangeFile,
    Channel,
    ChannelRevision,
    File,
    Option,
    OptionRevision,
    OptionRevisionFile
  }

  defp create_channel!(name) do
    Channel.create!(%{
      name: name,
      display_name: name,
      status: :active,
      is_stable: false
    })
  end

  defp create_channel_revision!(channel_id, revision, released_at) do
    Ash.create!(ChannelRevision, %{
      channel_id: channel_id,
      revision: revision,
      released_at: released_at
    })
  end

  defp create_change!(number, attrs) do
    base = %{
      number: number,
      title: "change #{number}",
      state: :merged,
      author: "tester",
      url: "https://github.com/NixOS/nixpkgs/pull/#{number}",
      base_ref: "master",
      processing_status: :processed
    }

    id_map = Change.bulk_upsert_all([Map.merge(base, attrs)])
    Ash.get!(Change, id_map[number])
  end

  defp create_file!(path) do
    File.bulk_upsert_all([path])
    |> Map.fetch!(path)
    |> then(&Ash.get!(File, &1))
  end

  defp link_change_file!(change_id, file_id) do
    ChangeFile.bulk_insert_all([%{change_id: change_id, file_id: file_id}])
  end

  defp create_option_with_revision_file!(name, channel_revision_id, file_id) do
    %{^name => option_id} = Option.bulk_upsert_all([%{name: name}])

    %{^option_id => option_revision_id} =
      OptionRevision.bulk_insert_all([
        %{
          option_id: option_id,
          channel_revision_id: channel_revision_id,
          description: "doc for #{name}",
          type: "boolean",
          default: "false",
          example: nil,
          read_only: false,
          loc: ["services", name],
          related_packages: nil
        }
      ])

    OptionRevisionFile.bulk_insert_all([
      %{option_revision_id: option_revision_id, file_id: file_id}
    ])

    Ash.get!(Option, option_id)
  end

  describe "prefix_counts_by_change_and_channel_revision/2" do
    test "folds option names to two-segment prefixes with counts, sorted by prefix" do
      channel = create_channel!("nixos-unstable")
      cr = create_channel_revision!(channel.id, "pfx000aaa111", ~U[2026-04-01 10:00:00Z])

      change = create_change!(8201, %{title: "touches multiple modules"})

      file_a = create_file!("nixos/modules/services/web-servers/nginx/default.nix")
      file_b = create_file!("nixos/modules/services/databases/postgresql.nix")
      file_c = create_file!("nixos/modules/networking/firewall.nix")

      link_change_file!(change.id, file_a.id)
      link_change_file!(change.id, file_b.id)
      link_change_file!(change.id, file_c.id)

      create_option_with_revision_file!("services.nginx.enable", cr.id, file_a.id)
      create_option_with_revision_file!("services.nginx.virtualHosts", cr.id, file_a.id)
      create_option_with_revision_file!("services.postgresql.enable", cr.id, file_b.id)
      create_option_with_revision_file!("networking.firewall.enable", cr.id, file_c.id)

      assert Option.prefix_counts_by_change_and_channel_revision(change.id, cr.id) == [
               {"networking.firewall", 1},
               {"services.nginx", 2},
               {"services.postgresql", 1}
             ]
    end

    test "uses the bare name when an option has no dots" do
      channel = create_channel!("nixos-unstable")
      cr = create_channel_revision!(channel.id, "pfx111bbb222", ~U[2026-04-01 10:00:00Z])

      change = create_change!(8202, %{title: "touches a top-level option"})
      file = create_file!("nixos/modules/system/boot/something.nix")
      link_change_file!(change.id, file.id)

      create_option_with_revision_file!("environment", cr.id, file.id)

      assert Option.prefix_counts_by_change_and_channel_revision(change.id, cr.id) ==
               [{"environment", 1}]
    end

    test "ignores option revisions belonging to other channel revisions" do
      channel = create_channel!("nixos-unstable")
      cr_main = create_channel_revision!(channel.id, "scoped00aaa11", ~U[2026-04-01 10:00:00Z])
      cr_other = create_channel_revision!(channel.id, "scoped00bbb22", ~U[2026-04-02 10:00:00Z])

      change = create_change!(8204, %{title: "touches one file"})
      file = create_file!("nixos/modules/services/web-servers/nginx/default.nix")
      link_change_file!(change.id, file.id)

      # Same option, present in both revisions, both linked to the touched file.
      create_option_with_revision_file!("services.nginx.enable", cr_main.id, file.id)
      create_option_with_revision_file!("services.nginx.enable", cr_other.id, file.id)

      # Scoping to one revision returns exactly one match (no double-counting).
      assert Option.prefix_counts_by_change_and_channel_revision(change.id, cr_main.id) ==
               [{"services.nginx", 1}]
    end

    test "returns [] for a change with no affected options in the revision" do
      channel = create_channel!("nixos-unstable")
      cr = create_channel_revision!(channel.id, "empty000aaa11", ~U[2026-04-01 10:00:00Z])
      change = create_change!(8203, %{title: "nothing"})

      assert Option.prefix_counts_by_change_and_channel_revision(change.id, cr.id) == []
    end
  end
end
