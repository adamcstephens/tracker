defmodule Tracker.Ingestion.CronWorkerTest do
  use Tracker.DataCase, async: false

  import ExUnit.CaptureLog

  alias Tracker.Ingestion.{CronWorker, IngestionRun, Pipeline}
  alias Tracker.Nixpkgs.{Channel, Release}

  @stub __MODULE__.Pointer

  @old_revision "aaa1111" <> String.duplicate("0", 33)
  @new_revision "ccc2222" <> String.duplicate("0", 33)

  setup do
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

    old_release = %{
      base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-aaa1111",
      released_at: ~U[2025-06-01 00:00:00Z],
      revision: @old_revision
    }

    Release.upsert!(Map.put(old_release, :channel_id, channel.id))

    Application.put_env(:tracker, :channel_pointer_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.delete_env(:tracker, :channel_pointer_req_options)
      Application.delete_env(:tracker, :releases_fetcher)
    end)

    {:ok, channel: channel, old_release: old_release}
  end

  defp reload(channel), do: Ash.get!(Channel, channel.id)

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

      channel = reload(channel)
      assert channel.pointer_revision == old_release.revision
      assert channel.pointer_etag == ~s("etag-v1")
      assert channel.pointer_last_modified == "Wed, 21 May 2026 12:00:00 GMT"
    end

    test "200 with new revision triggers refresh and creates a pipeline", %{channel: channel} do
      new_release = %{
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-ccc2222",
        released_at: ~U[2025-06-20 00:00:00Z],
        revision: @new_revision
      }

      Application.put_env(
        :tracker,
        :releases_fetcher,
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

      assert reload(channel).pointer_revision == @new_revision
    end

    test "304 still syncs when stored pointer revision has no pipeline", %{channel: channel} do
      # Simulates production: a prior poll stored a pointer for a revision
      # that never got a pipeline. Upstream now returns 304 against the
      # conditional headers, but the cron should still detect the gap.
      new_release = %{
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-ccc2222",
        released_at: ~U[2025-06-20 00:00:00Z],
        revision: @new_revision
      }

      Release.upsert!(Map.put(new_release, :channel_id, channel.id))

      Channel.put_pointer!(channel, %{
        pointer_etag: ~s("etag-v2"),
        pointer_last_modified: "Wed, 25 May 2026 14:59:39 GMT",
        pointer_revision: @new_revision
      })

      Application.put_env(
        :tracker,
        :releases_fetcher,
        fn "nixos-unstable" -> [new_release] end
      )

      Req.Test.stub(@stub, fn conn ->
        Plug.Conn.send_resp(conn, 304, "")
      end)

      before = length(Pipeline.for_channel!(channel.id))
      assert :ok = perform_job(CronWorker, %{}, queue: :ingestion)
      assert length(Pipeline.for_channel!(channel.id)) == before + 1
    end

    test "200 with new revision creates a pipeline even when the release is already known",
         %{channel: channel, old_release: old_release} do
      new_release = %{
        base_url: "https://releases.nixos.org/nixos/unstable/nixos-25.05pre-ccc2222",
        released_at: ~U[2025-06-20 00:00:00Z],
        revision: @new_revision
      }

      Release.upsert!(Map.put(new_release, :channel_id, channel.id))

      Application.put_env(
        :tracker,
        :releases_fetcher,
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

    test "sends If-None-Match and If-Modified-Since from stored pointer", %{channel: channel} do
      Channel.put_pointer!(channel, %{
        pointer_etag: ~s("prev-etag"),
        pointer_last_modified: "Tue, 20 May 2026 00:00:00 GMT",
        pointer_revision: @old_revision
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
      Tracker.Repo.delete_all(Tracker.Nixpkgs.Release)
      Tracker.Repo.delete_all(Tracker.Nixpkgs.Channel)

      assert :ok = perform_job(CronWorker, %{}, queue: :ingestion)
    end
  end
end
