defmodule Tracker.Nixpkgs.ReleaseTest do
  use Tracker.DataCase, async: false

  alias Tracker.Nixpkgs.{Channel, Release}

  defp create_channel(name \\ "nixos-unstable") do
    Channel.create!(%{
      name: name,
      display_name: name,
      status: :active,
      is_stable: false
    })
  end

  defp rev(prefix), do: prefix <> String.duplicate("0", 40 - String.length(prefix))

  describe "refresh/2" do
    test "upserts listed releases with their revisions" do
      channel = create_channel()

      fetcher = fn "nixos-unstable" ->
        [
          %{
            base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-bbb",
            released_at: ~U[2025-06-10 00:00:00Z],
            revision: rev("bbb")
          },
          %{
            base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-aaa",
            released_at: ~U[2025-06-01 00:00:00Z],
            revision: rev("aaa")
          }
        ]
      end

      assert :ok = Release.refresh(channel, releases_fetcher: fetcher)

      releases = Release.by_channel!(channel.id)

      assert [rev("bbb"), rev("aaa")] == Enum.map(releases, & &1.revision)
      assert Enum.all?(releases, &(&1.channel_id == channel.id))
    end

    test "is idempotent and never clobbers an already resolved revision" do
      channel = create_channel()
      base_url = "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-aaa"

      resolved = fn _ ->
        [%{base_url: base_url, released_at: ~U[2025-06-01 00:00:00Z], revision: rev("aaa")}]
      end

      unresolved_fetcher = fn _ ->
        [%{base_url: base_url, released_at: ~U[2025-06-01 00:00:00Z]}]
      end

      assert :ok = Release.refresh(channel, releases_fetcher: resolved)
      assert :ok = Release.refresh(channel, releases_fetcher: unresolved_fetcher)

      assert [%Release{revision: revision}] = Release.by_channel!(channel.id)
      assert revision == rev("aaa")
    end

    test "resolves missing revisions for previously unresolved rows" do
      channel = create_channel()
      base_url = "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-aaa"

      unresolved_fetcher = fn _ ->
        [%{base_url: base_url, released_at: ~U[2025-06-01 00:00:00Z]}]
      end

      resolved_fetcher = fn _ ->
        [%{base_url: base_url, released_at: ~U[2025-06-01 00:00:00Z], revision: rev("aaa")}]
      end

      assert :ok = Release.refresh(channel, releases_fetcher: unresolved_fetcher)
      assert [%Release{revision: nil}] = Release.by_channel!(channel.id)

      assert :ok = Release.refresh(channel, releases_fetcher: resolved_fetcher)
      assert [%Release{revision: revision}] = Release.by_channel!(channel.id)
      assert revision == rev("aaa")
    end

    test "does not touch other channels" do
      channel = create_channel()
      other = create_channel("nixos-25.05")

      Release.upsert!(%{
        channel_id: other.id,
        base_url: "https://releases.nixos.org/nixos/25.05/nixos-other",
        released_at: ~U[2025-05-01 00:00:00Z],
        revision: rev("other")
      })

      fetcher = fn _ ->
        [
          %{
            base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-aaa",
            released_at: ~U[2025-06-01 00:00:00Z],
            revision: rev("aaa")
          }
        ]
      end

      assert :ok = Release.refresh(channel, releases_fetcher: fetcher)

      assert [%Release{revision: other_rev}] = Release.by_channel!(other.id)
      assert other_rev == rev("other")
    end
  end

  describe "queries" do
    setup do
      channel = create_channel()

      for {prefix, released_at} <- [
            {"aaa", ~U[2025-06-01 00:00:00Z]},
            {"bbb", ~U[2025-06-10 00:00:00Z]},
            {"ccc", ~U[2025-06-20 00:00:00Z]}
          ] do
        Release.upsert!(%{
          channel_id: channel.id,
          base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-#{prefix}",
          released_at: released_at,
          revision: rev(prefix)
        })
      end

      {:ok, channel: channel}
    end

    test "by_channel returns releases newest first", %{channel: channel} do
      assert [rev("ccc"), rev("bbb"), rev("aaa")] ==
               Release.by_channel!(channel.id) |> Enum.map(& &1.revision)
    end

    test "previous_before returns the chronologically previous release", %{channel: channel} do
      bbb = rev("bbb")
      aaa = rev("aaa")

      assert {:ok, %Release{revision: ^bbb}} =
               Release.previous_before(channel.id, ~U[2025-06-20 00:00:00Z])

      assert {:ok, %Release{revision: ^aaa}} =
               Release.previous_before(channel.id, ~U[2025-06-10 00:00:00Z])
    end

    test "previous_before returns nil before the oldest release", %{channel: channel} do
      assert {:ok, nil} = Release.previous_before(channel.id, ~U[2025-06-01 00:00:00Z])
    end

    test "find_by_revision returns the matching release", %{channel: channel} do
      bbb = rev("bbb")
      assert {:ok, %Release{revision: ^bbb}} = Release.find_by_revision(channel.id, bbb)
      assert {:ok, nil} = Release.find_by_revision(channel.id, rev("zzz"))
    end

    test "newest returns the most recent release", %{channel: channel} do
      ccc = rev("ccc")
      assert {:ok, %Release{revision: ^ccc}} = Release.newest(channel.id)

      other = create_channel("empty-channel")
      assert {:ok, nil} = Release.newest(other.id)
    end

    test "without_pipeline excludes releases with a non-failed pipeline", %{channel: channel} do
      run =
        Tracker.Ingestion.IngestionRun.create!(%{
          type: :cron_update,
          started_at: DateTime.utc_now()
        })

      Tracker.Ingestion.Pipeline.create!(%{
        channel_id: channel.id,
        revision: rev("aaa"),
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-aaa",
        released_at: ~U[2025-06-01 00:00:00Z],
        active_steps: [:create_revision],
        sequence: 0,
        ingestion_run_id: run.id
      })

      failed =
        Tracker.Ingestion.Pipeline.create!(%{
          channel_id: channel.id,
          revision: rev("bbb"),
          base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-bbb",
          released_at: ~U[2025-06-10 00:00:00Z],
          active_steps: [:create_revision],
          sequence: 1,
          ingestion_run_id: run.id
        })

      failed
      |> Tracker.Ingestion.Pipeline.start!()
      |> Tracker.Ingestion.Pipeline.mark_failed!(:create_revision, "boom")

      assert [rev("bbb"), rev("ccc")] ==
               Release.without_pipeline!(channel.id) |> Enum.map(& &1.revision)
    end
  end

  describe "s3_prefix/1" do
    test "nixos channels map to their grouping directory" do
      assert Release.s3_prefix("nixos-unstable") == "nixos/unstable/"
      assert Release.s3_prefix("nixos-26.05-small") == "nixos/26.05-small/"
    end

    test "nixpkgs release channels map to their grouping directory" do
      assert Release.s3_prefix("nixpkgs-26.05-darwin") == "nixpkgs/26.05-darwin/"
    end

    test "nixpkgs-unstable lists the whole nixpkgs/ tree, having no grouping dir" do
      assert Release.s3_prefix("nixpkgs-unstable") == "nixpkgs/"
    end
  end

  describe "release_key?/2" do
    test "nixpkgs-unstable keeps only dated unstable snapshot markers" do
      assert Release.release_key?(
               "nixpkgs-unstable",
               "nixpkgs/nixpkgs-26.11pre1020805.89570f24e97e"
             )

      # darwin sibling channel under the shared nixpkgs/ prefix
      refute Release.release_key?("nixpkgs-unstable", "nixpkgs/26.05-darwin")

      # ancient underscore-separated tag
      refute Release.release_key?(
               "nixpkgs-unstable",
               "nixpkgs/nixpkgs-1.0pre22121_e2e1526"
             )

      # ancient non-pre tag
      refute Release.release_key?("nixpkgs-unstable", "nixpkgs/nixpkgs-0.11")
    end

    test "other channels accept every key under their scoped prefix" do
      assert Release.release_key?("nixos-unstable", "nixos/unstable/nixos-26.05pre1.abc123")
      assert Release.release_key?("nixpkgs-26.05-darwin", "nixpkgs/26.05-darwin/whatever")
    end
  end

  describe "parse_releases/3" do
    test "parses released_at to DateTime" do
      contents = [
        %{
          "Key" => "nixos/unstable/nixos-unstable-new.abc1234",
          "LastModified" => "2025-06-15T10:00:00Z"
        }
      ]

      [release] = Release.parse_releases(contents)

      assert release.released_at == ~U[2025-06-15 10:00:00Z]

      assert release.base_url ==
               "https://releases.nixos.org/nixos/unstable/nixos-unstable-new.abc1234"
    end

    test "excludes releases older than the default cutoff (2020-03-27)" do
      contents = [
        %{
          "Key" => "nixos/unstable/nixos-unstable-new.abc1234",
          "LastModified" => "2020-06-01T10:00:00Z"
        },
        %{
          "Key" => "nixos/unstable/nixos-unstable-old.def5678",
          "LastModified" => "2020-01-01T23:59:59Z"
        }
      ]

      releases = Release.parse_releases(contents)

      assert length(releases) == 1
      assert hd(releases).base_url =~ "abc1234"
    end

    test "accepts an earlier `from` to include older releases" do
      contents = [
        %{
          "Key" => "nixos/unstable/nixos-unstable-new.abc1234",
          "LastModified" => "2025-06-15T10:00:00Z"
        },
        %{
          "Key" => "nixos/unstable/nixos-unstable-old.def5678",
          "LastModified" => "2021-05-01T00:00:00Z"
        }
      ]

      releases = Release.parse_releases(contents, ~U[2020-03-27 00:00:00Z])

      assert length(releases) == 2
    end

    test "excludes releases newer than `until`, bounding a window" do
      contents = [
        %{
          "Key" => "nixos/unstable/nixos-unstable-late.aaa",
          "LastModified" => "2021-09-01T00:00:00Z"
        },
        %{
          "Key" => "nixos/unstable/nixos-unstable-early.bbb",
          "LastModified" => "2021-04-01T00:00:00Z"
        }
      ]

      releases =
        Release.parse_releases(contents, ~U[2021-01-01 00:00:00Z], ~U[2021-06-01 00:00:00Z])

      assert length(releases) == 1
      assert hd(releases).base_url =~ "bbb"
    end
  end
end
