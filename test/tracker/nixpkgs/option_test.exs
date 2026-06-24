defmodule Tracker.Nixpkgs.OptionTest do
  use Tracker.DataCase, async: true

  alias Tracker.Fixtures
  alias Tracker.Nixpkgs.{ChangeFile, ChannelRevision, File, Option}

  describe "prefix_counts_by_change_and_channel_revision/2" do
    setup do
      channel = Fixtures.channel!("nixos-unstable")

      cr =
        ChannelRevision.create!(%{
          channel_id: channel.id,
          revision: "prefixcnt0001",
          released_at: ~U[2026-04-01 10:00:00Z]
        })

      Fixtures.load_options(
        %{
          "services.nginx.enable" => %{"declarations" => ["a.nix"]},
          "services.nginx.user" => %{"declarations" => ["a.nix"]},
          "programs.vim.enable" => %{"declarations" => ["b.nix"]}
        },
        cr
      )

      %{cr: cr}
    end

    test "folds the change's declared options into two-segment prefix counts", %{cr: cr} do
      change = Fixtures.change!()

      ChangeFile.bulk_insert_all([
        %{change_id: change.id, file_id: File.get_by_path!("a.nix").id}
      ])

      assert Option.prefix_counts_by_change_and_channel_revision(change.id, cr.id) ==
               [{"services.nginx", 2}]
    end

    test "scopes the option set to the given channel revision", %{cr: cr} do
      change = Fixtures.change!()

      ChangeFile.bulk_insert_all([
        %{change_id: change.id, file_id: File.get_by_path!("a.nix").id},
        %{change_id: change.id, file_id: File.get_by_path!("b.nix").id}
      ])

      assert Option.prefix_counts_by_change_and_channel_revision(change.id, cr.id) ==
               [{"programs.vim", 1}, {"services.nginx", 2}]
    end

    test "is empty when the change touches no declaring files", %{cr: cr} do
      change = Fixtures.change!()

      assert Option.prefix_counts_by_change_and_channel_revision(change.id, cr.id) == []
    end
  end
end
