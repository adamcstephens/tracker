defmodule Tracker.Ingestion.CronWorkerTest do
  use Tracker.DataCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Tracker.Ingestion.{CronWorker, IngestionRun, Pipeline}
  alias Tracker.Nixpkgs.{Channel, ReleaseCache}
  alias Tracker.Nixpkgs.ReleaseCache.Release

  @cache_name :cron_worker_test_cache
  @stub __MODULE__.Pointer

  @old_revision "aaa1111" <> String.duplicate("0", 33)
  @new_revision "ccc2222" <> String.duplicate("0", 33)

  setup do
    {:ok, _pid} = ReleaseCache.start_link(name: @cache_name, load: false)

    channel =
      Channel.create!(%{
        name: "nixos-unstable",
        display_name: "NixOS Unstable",
        status: :active,
        is_stable: false
      })

    # Seed a completed pipeline so PipelineStarter.sync_channel does not :noop
    run = IngestionRun.create!(%{type: :cron_update, started_at: DateTime.utc_now()})

    Pipeline.create!(%{
      channel_id: channel.id,
      revision: @old_revision,
      base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-aaa1111",
      released_at: ~U[2025-06-01 00:00:00Z],
      active_steps: [:create_revision, :load_packages, :detect_package_events, :finalize],
      sequence: 0,
      ingestion_run_id: run.id
    })
    |> Pipeline.start!()
    |> Pipeline.mark_completed!()

    old_release = %Release{
      base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-aaa1111",
      released_at: ~U[2025-06-01 00:00:00Z],
      revision: @old_revision
    }

    ReleaseCache.put_releases(@cache_name, "nixos-unstable", [old_release])

    Application.put_env(:tracker, :release_cache_name, @cache_name)
    Application.put_env(:tracker, :channel_pointer_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.delete_env(:tracker, :release_cache_name)
      Application.delete_env(:tracker, :channel_pointer_req_options)
      Application.delete_env(:tracker, :release_cache_fetcher)
    end)

    {:ok, channel: channel, old_release: old_release}
  end

  describe "perform/1" do
    test "304 from pointer is a noop", %{channel: channel} do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("etag", ~s("etag-v1"))
        |> Plug.Conn.send_resp(304, "")
      end)

      before = length(Pipeline.for_channel!(channel.id))
      assert :ok = perform_job(CronWorker, %{}, queue: :ingestion)
      assert length(Pipeline.for_channel!(channel.id)) == before
    end

    test "200 with unchanged revision updates pointer but does not sync", %{
      channel: channel,
      old_release: old_release
    } do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("etag", ~s("etag-v1"))
        |> Plug.Conn.put_resp_header("last-modified", "Wed, 21 May 2026 12:00:00 GMT")
        |> Plug.Conn.send_resp(200, old_release.revision <> "\n")
      end)

      before = length(Pipeline.for_channel!(channel.id))
      assert :ok = perform_job(CronWorker, %{}, queue: :ingestion)
      assert length(Pipeline.for_channel!(channel.id)) == before

      pointer = ReleaseCache.get_pointer(@cache_name, "nixos-unstable")
      assert pointer.revision == old_release.revision
      assert pointer.etag == ~s("etag-v1")
      assert pointer.last_modified == "Wed, 21 May 2026 12:00:00 GMT"
    end

    test "200 with new revision triggers refresh and creates a pipeline", %{channel: channel} do
      new_release = %Release{
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-ccc2222",
        released_at: ~U[2025-06-20 00:00:00Z],
        revision: @new_revision
      }

      Application.put_env(
        :tracker,
        :release_cache_fetcher,
        fn "nixos-unstable" -> [new_release] end
      )

      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("etag", ~s("etag-v2"))
        |> Plug.Conn.send_resp(200, @new_revision <> "\n")
      end)

      before = length(Pipeline.for_channel!(channel.id))
      assert :ok = perform_job(CronWorker, %{}, queue: :ingestion)
      assert length(Pipeline.for_channel!(channel.id)) == before + 1

      assert ReleaseCache.get_pointer(@cache_name, "nixos-unstable").revision == @new_revision
    end

    test "304 still syncs when stored pointer revision has no pipeline", %{channel: channel} do
      # Simulates production: a prior poll stored a pointer for a revision
      # that never got a pipeline. Upstream now returns 304 against the
      # conditional headers, but the cron should still detect the gap.
      new_release = %Release{
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-ccc2222",
        released_at: ~U[2025-06-20 00:00:00Z],
        revision: @new_revision
      }

      ReleaseCache.put_releases(@cache_name, "nixos-unstable", [new_release])

      ReleaseCache.put_pointer(@cache_name, "nixos-unstable", %{
        etag: ~s("etag-v2"),
        last_modified: "Wed, 25 May 2026 14:59:39 GMT",
        revision: @new_revision
      })

      Application.put_env(
        :tracker,
        :release_cache_fetcher,
        fn "nixos-unstable" -> [new_release] end
      )

      Req.Test.stub(@stub, fn conn ->
        Plug.Conn.send_resp(conn, 304, "")
      end)

      before = length(Pipeline.for_channel!(channel.id))
      assert :ok = perform_job(CronWorker, %{}, queue: :ingestion)
      assert length(Pipeline.for_channel!(channel.id)) == before + 1
    end

    test "200 with new revision creates a pipeline even when ReleaseCache already knows the release",
         %{channel: channel, old_release: old_release} do
      new_release = %Release{
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-ccc2222",
        released_at: ~U[2025-06-20 00:00:00Z],
        revision: @new_revision
      }

      ReleaseCache.put_releases(@cache_name, "nixos-unstable", [new_release, old_release])

      Application.put_env(
        :tracker,
        :release_cache_fetcher,
        fn "nixos-unstable" -> [new_release, old_release] end
      )

      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("etag", ~s("etag-v2"))
        |> Plug.Conn.send_resp(200, @new_revision <> "\n")
      end)

      before = length(Pipeline.for_channel!(channel.id))
      assert :ok = perform_job(CronWorker, %{}, queue: :ingestion)
      assert length(Pipeline.for_channel!(channel.id)) == before + 1
    end

    test "sends If-None-Match and If-Modified-Since from stored pointer" do
      ReleaseCache.put_pointer(@cache_name, "nixos-unstable", %{
        etag: ~s("prev-etag"),
        last_modified: "Tue, 20 May 2026 00:00:00 GMT",
        revision: @old_revision
      })

      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 304, "")
      end)

      assert :ok = perform_job(CronWorker, %{}, queue: :ingestion)

      assert_receive {:headers, headers}
      assert {"if-none-match", ~s("prev-etag")} in headers
      assert {"if-modified-since", "Tue, 20 May 2026 00:00:00 GMT"} in headers
    end

    test "logs summary counts", %{old_release: old_release} do
      Logger.put_module_level(CronWorker, :info)
      on_exit(fn -> Logger.delete_module_level(CronWorker) end)

      Req.Test.stub(@stub, fn conn ->
        Plug.Conn.send_resp(conn, 200, old_release.revision <> "\n")
      end)

      log =
        capture_log(fn ->
          assert :ok = perform_job(CronWorker, %{}, queue: :ingestion)
        end)

      assert log =~ ~s(msg: "channel poll started")
      assert log =~ "active_channels: 1"
      assert log =~ ~s(msg: "channel poll finished")
      assert log =~ ~r/unchanged: \d+/
      assert log =~ ~r/changed: \d+/
      assert log =~ ~r/created: \d+/
      assert log =~ ~r/duration_ms: \d+/
    end

    test "succeeds with no active channels" do
      Tracker.Repo.delete_all(Tracker.Ingestion.Pipeline)
      Tracker.Repo.delete_all(Tracker.Ingestion.IngestionRun)
      Tracker.Repo.delete_all(Tracker.Nixpkgs.Channel)

      assert :ok = perform_job(CronWorker, %{}, queue: :ingestion)
    end
  end
end
