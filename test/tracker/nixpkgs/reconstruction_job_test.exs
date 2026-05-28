defmodule Tracker.Nixpkgs.ReconstructionJobTest do
  use Tracker.DataCase, async: false

  alias Tracker.Accounts.User
  alias Tracker.Nixpkgs.{Change, ChangeArtifactCache, ReconstructionJob, S3Cache}

  setup do
    {:ok, worker} =
      User.create_service_account(
        "recon-#{System.unique_integer([:positive])}",
        [:reconstruction_worker],
        authorize?: false
      )

    fetcher = fn _sha -> {:ok, "base-sha-0000"} end
    Application.put_env(:tracker, :reconstruction_parent_sha_fetcher, fetcher)
    on_exit(fn -> Application.delete_env(:tracker, :reconstruction_parent_sha_fetcher) end)

    %{worker: worker, fetcher: fetcher}
  end

  describe "claim/1" do
    test "picks the most-recent expired merged change and creates a claimed job", ctx do
      _ineligible_unmerged = insert_change!(processing_status: :artifact_expired)
      _ineligible_processed = insert_change!(processing_status: :processed)

      older =
        insert_change!(
          processing_status: :artifact_expired,
          merge_commit_sha: "abc1",
          merged_at: ~U[2024-01-01 00:00:00Z]
        )

      newer =
        insert_change!(
          processing_status: :artifact_expired,
          merge_commit_sha: "abc2",
          merged_at: ~U[2026-04-01 00:00:00Z]
        )

      assert {:ok, %{result: :claimed} = claim} =
               ReconstructionJob.claim(actor: ctx.worker)

      assert claim.change_id == newer.id
      assert claim.pr_number == newer.number
      assert claim.head_sha == "abc2"
      assert claim.base_sha == "base-sha-0000"
      assert is_binary(claim.lease_token) and byte_size(claim.lease_token) >= 16
      assert DateTime.compare(claim.lease_expires_at, DateTime.utc_now()) == :gt

      refute Enum.any?(jobs_for_change(older.id), &(&1.status == :claimed))
      assert Enum.any?(jobs_for_change(newer.id), &(&1.status == :claimed))
    end

    test "returns :none when no eligible change exists", ctx do
      insert_change!(processing_status: :processed)
      insert_change!(processing_status: :artifact_expired, merge_commit_sha: nil)

      assert {:ok, %{result: :none}} =
               ReconstructionJob.claim(actor: ctx.worker)
    end

    test "skips changes with an active claim and picks the next", ctx do
      held =
        insert_change!(
          processing_status: :artifact_expired,
          merge_commit_sha: "held",
          merged_at: ~U[2026-05-01 00:00:00Z]
        )

      next =
        insert_change!(
          processing_status: :artifact_expired,
          merge_commit_sha: "next",
          merged_at: ~U[2026-04-15 00:00:00Z]
        )

      # Pre-existing live claim on `held`.
      {:ok, _} = insert_claim!(held.id, :claimed, DateTime.add(DateTime.utc_now(), 3600, :second))

      assert {:ok, %{result: :claimed, change_id: claimed_id}} =
               ReconstructionJob.claim(actor: ctx.worker)

      assert claimed_id == next.id
    end

    test "demotes a stale claim and inserts a fresh one for the same change", ctx do
      change =
        insert_change!(
          processing_status: :artifact_expired,
          merge_commit_sha: "stale",
          merged_at: ~U[2026-03-01 00:00:00Z]
        )

      stale_at = DateTime.add(DateTime.utc_now(), -3600, :second)
      {:ok, stale} = insert_claim!(change.id, :claimed, stale_at)

      assert {:ok, %{result: :claimed} = claim} =
               ReconstructionJob.claim(actor: ctx.worker)

      assert claim.change_id == change.id
      refute claim.job_id == stale.id

      reloaded = Ash.get!(ReconstructionJob, stale.id, authorize?: false)
      assert reloaded.status == :failed
      assert reloaded.last_error == "lease expired"
    end

    test "non-worker actor is forbidden", _ctx do
      insert_change!(
        processing_status: :artifact_expired,
        merge_commit_sha: "anything",
        merged_at: ~U[2026-04-01 00:00:00Z]
      )

      {:ok, plain_user} =
        User.create_service_account("plain-#{System.unique_integer([:positive])}", [:user],
          authorize?: false
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               ReconstructionJob.claim(actor: plain_user)
    end
  end

  describe "fail/4" do
    setup ctx do
      change =
        insert_change!(
          processing_status: :artifact_expired,
          merge_commit_sha: "fail-test",
          merged_at: ~U[2026-04-01 00:00:00Z]
        )

      {:ok, claim} =
        ReconstructionJob.claim(actor: ctx.worker)

      assert claim.change_id == change.id
      Map.put(ctx, :claim, claim)
    end

    test "marks the job :failed with reason+detail", ctx do
      assert {:ok, %{result: :failed, job_id: id}} =
               ReconstructionJob.fail(
                 ctx.claim.job_id,
                 ctx.claim.lease_token,
                 "nix_eval_error",
                 "evaluation aborted",
                 actor: ctx.worker
               )

      assert id == ctx.claim.job_id
      job = Ash.get!(ReconstructionJob, id, authorize?: false)
      assert job.status == :failed
      assert job.last_error == "nix_eval_error: evaluation aborted"
    end

    test "omits detail when not provided", ctx do
      assert {:ok, _} =
               ReconstructionJob.fail(
                 ctx.claim.job_id,
                 ctx.claim.lease_token,
                 "timeout",
                 nil,
                 actor: ctx.worker
               )

      job = Ash.get!(ReconstructionJob, ctx.claim.job_id, authorize?: false)
      assert job.last_error == "timeout"
    end

    test "rejects an incorrect lease_token", ctx do
      assert {:error, error} =
               ReconstructionJob.fail(
                 ctx.claim.job_id,
                 "wrong-token",
                 "x",
                 "y",
                 actor: ctx.worker
               )

      assert error_reason(error) == :invalid_lease_token
    end

    test "rejects fail on an already-succeeded job", ctx do
      ReconstructionJob.get_by_id!(ctx.claim.job_id, authorize?: false)
      |> Ash.Changeset.for_update(:update_internal, %{status: :succeeded})
      |> Ash.update!(authorize?: false)

      assert {:error, error} =
               ReconstructionJob.fail(
                 ctx.claim.job_id,
                 ctx.claim.lease_token,
                 "x",
                 "y",
                 actor: ctx.worker
               )

      assert error_reason(error) == :not_claimed
    end

    test "non-worker actor is forbidden", ctx do
      {:ok, plain_user} =
        User.create_service_account("plain-#{System.unique_integer([:positive])}", [:user],
          authorize?: false
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               ReconstructionJob.fail(
                 ctx.claim.job_id,
                 ctx.claim.lease_token,
                 "x",
                 "y",
                 actor: plain_user
               )
    end
  end

  describe "submit_result/3" do
    setup ctx do
      config = %S3Cache.Config{
        bucket: "test-bucket",
        access_key_id: "test-key",
        secret_access_key: "test-secret",
        endpoint: "http://localhost:4444",
        region: "garage",
        plug: {Req.Test, __MODULE__.S3}
      }

      Application.put_env(:tracker, :s3_cache, Map.from_struct(config))
      on_exit(fn -> Application.delete_env(:tracker, :s3_cache) end)

      store = stub_s3_store()

      change =
        insert_change!(
          processing_status: :artifact_expired,
          merge_commit_sha: "result-test",
          merged_at: ~U[2026-04-01 00:00:00Z]
        )

      {:ok, claim} =
        ReconstructionJob.claim(actor: ctx.worker)

      assert claim.change_id == change.id

      Map.merge(ctx, %{claim: claim, change: change, store: store, config: config})
    end

    test "validates zip, writes S3, marks :succeeded, enqueues refresh", ctx do
      zip = build_comparison_zip()

      assert {:ok, %{result: :succeeded, job_id: id}} =
               ReconstructionJob.submit_result(
                 ctx.claim.job_id,
                 ctx.claim.lease_token,
                 zip,
                 actor: ctx.worker
               )

      assert id == ctx.claim.job_id

      job = Ash.get!(ReconstructionJob, id, authorize?: false)
      assert job.status == :succeeded

      pr = ctx.change.number
      zip_key = "/test-bucket/" <> ChangeArtifactCache.cache_key(pr, "comparison")
      meta_key = "/test-bucket/" <> ChangeArtifactCache.meta_key(pr)

      assert_received {:s3_put, ^zip_key}
      assert_received {:s3_put, ^meta_key}

      meta_bin = :ets.lookup_element(ctx.store, meta_key, 2)
      meta = :erlang.binary_to_term(meta_bin)

      assert %ChangeArtifactCache.Meta{source: :merge, provenance: :reconstruction, run_id: nil} =
               meta

      assert_enqueued worker: Tracker.Nixpkgs.ChangeArtifactRefreshWorker,
                      args: %{number: pr, reason: "merged"}
    end

    test "rejects an invalid zip (not a zip)", ctx do
      assert {:error, _error} =
               ReconstructionJob.submit_result(
                 ctx.claim.job_id,
                 ctx.claim.lease_token,
                 "not-a-zip",
                 actor: ctx.worker
               )

      job = Ash.get!(ReconstructionJob, ctx.claim.job_id, authorize?: false)
      assert job.status == :claimed
    end

    test "rejects an incorrect lease_token", ctx do
      zip = build_comparison_zip()

      assert {:error, error} =
               ReconstructionJob.submit_result(
                 ctx.claim.job_id,
                 "wrong",
                 zip,
                 actor: ctx.worker
               )

      assert error_reason(error) == :invalid_lease_token
    end

    test "non-worker actor is forbidden", ctx do
      {:ok, plain_user} =
        User.create_service_account("plain-#{System.unique_integer([:positive])}", [:user],
          authorize?: false
        )

      zip = build_comparison_zip()

      assert {:error, %Ash.Error.Forbidden{}} =
               ReconstructionJob.submit_result(
                 ctx.claim.job_id,
                 ctx.claim.lease_token,
                 zip,
                 actor: plain_user
               )
    end
  end

  defp build_comparison_zip do
    changed_paths =
      Jason.encode!(%{
        "attrdiff" => %{"added" => ["new-pkg"], "changed" => [], "removed" => []}
      })

    {:ok, {_, body}} =
      :zip.create(~c"test.zip", [{~c"changed-paths.json", changed_paths}], [:memory])

    body
  end

  defp stub_s3_store do
    store = :ets.new(:s3_store, [:set, :public])
    test_pid = self()

    Req.Test.stub(__MODULE__.S3, fn conn ->
      s3_key = conn.request_path
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case conn.method do
        "GET" ->
          case :ets.lookup(store, s3_key) do
            [{^s3_key, stored}] -> Plug.Conn.send_resp(conn, 200, stored)
            [] -> Plug.Conn.send_resp(conn, 404, "not found")
          end

        "PUT" ->
          :ets.insert(store, {s3_key, body})
          send(test_pid, {:s3_put, s3_key})
          Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    store
  end

  defp insert_change!(overrides) do
    base = %{
      number: System.unique_integer([:positive]) + 1_000_000,
      title: "test change",
      state: :merged,
      author: "tester",
      url: "https://github.com/NixOS/nixpkgs/pull/0",
      processing_status: :pending,
      merge_commit_sha: nil,
      merged_at: ~U[2026-01-01 00:00:00Z]
    }

    attrs = Map.merge(base, Map.new(overrides))

    id_map = Change.bulk_upsert_all([attrs])
    Ash.get!(Change, id_map[attrs.number])
  end

  defp insert_claim!(change_id, status, lease_expires_at) do
    now = DateTime.utc_now()

    ReconstructionJob
    |> Ash.Changeset.for_create(:create_internal, %{
      change_id: change_id,
      claimed_at: now,
      lease_expires_at: lease_expires_at,
      lease_token: "fixture-token-#{System.unique_integer([:positive])}",
      status: status
    })
    |> Ash.create(authorize?: false)
  end

  defp error_reason(%Ash.Error.Unknown{errors: [%{error: msg} | _]}) do
    msg
    |> String.replace_prefix("unknown error: :", "")
    |> String.to_existing_atom()
  end

  defp jobs_for_change(change_id) do
    require Ash.Query

    ReconstructionJob
    |> Ash.Query.filter(change_id == ^change_id)
    |> Ash.read!(authorize?: false)
  end
end
