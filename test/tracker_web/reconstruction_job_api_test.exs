defmodule TrackerWeb.ReconstructionJobApiTest do
  use TrackerWeb.ConnCase, async: false
  use Oban.Testing, repo: Tracker.Repo

  alias Tracker.Accounts.{ApiToken, User}
  alias Tracker.Nixpkgs.{Change, ReconstructionJob, S3Cache}

  setup do
    {:ok, worker} =
      User.create_service_account(
        "worker-#{System.unique_integer([:positive])}",
        [:reconstruction_worker],
        authorize?: false
      )

    {:ok, %{token: jwt}} = ApiToken.issue(worker.id, %{label: "test"}, actor: worker)

    %{worker: worker, jwt: jwt}
  end

  describe "POST /api/worker/json/reconstruction_jobs/claim" do
    test "with an eligible change, returns the claim payload", ctx do
      Application.put_env(
        :tracker,
        :reconstruction_parent_sha_fetcher,
        fn _ -> {:ok, "parent-sha"} end
      )

      on_exit(fn -> Application.delete_env(:tracker, :reconstruction_parent_sha_fetcher) end)

      change = insert_change!()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.jwt)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/worker/json/reconstruction_jobs/claim")

      assert conn.status == 201

      body = json_response_decode(conn)
      assert body["result"] == "claimed"
      assert body["change_id"] == change.id
      assert body["pr_number"] == change.number
      assert body["base_sha"] == "parent-sha"
      assert body["head_sha"] == "result-test"
      assert is_binary(body["lease_token"])
    end

    test "with no eligible change, returns success with result: none", ctx do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.jwt)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/worker/json/reconstruction_jobs/claim")

      assert conn.status == 201
      assert %{"result" => "none"} = json_response_decode(conn)
    end

    test "without a bearer token, returns 401", _ctx do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/worker/json/reconstruction_jobs/claim")

      assert conn.status == 401
    end

    test "with a non-worker token, returns 403", _ctx do
      {:ok, plain} =
        User.create_service_account(
          "plain-#{System.unique_integer([:positive])}",
          [:user],
          authorize?: false
        )

      {:ok, %{token: jwt}} = ApiToken.issue(plain.id, %{label: "test"}, actor: plain)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> jwt)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/worker/json/reconstruction_jobs/claim")

      assert conn.status == 403
    end
  end

  describe "GET /api/worker/json/open_api" do
    test "publishes claim and fail routes", ctx do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.jwt)
        |> get("/api/worker/json/open_api")

      assert conn.status == 200

      body = json_response_decode(conn)
      paths = body["paths"] || %{}
      assert Map.has_key?(paths, "/api/worker/json/reconstruction_jobs/claim")
      assert Map.has_key?(paths, "/api/worker/json/reconstruction_jobs/{id}/fail")
    end
  end

  describe "POST /api/worker/reconstruction_jobs/:id/result (multipart)" do
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

      Application.put_env(
        :tracker,
        :reconstruction_parent_sha_fetcher,
        fn _ -> {:ok, "base-sha-0000"} end
      )

      on_exit(fn -> Application.delete_env(:tracker, :reconstruction_parent_sha_fetcher) end)

      Req.Test.stub(__MODULE__.S3, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        case conn.method do
          "PUT" -> Plug.Conn.send_resp(conn, 200, "")
          "GET" -> Plug.Conn.send_resp(conn, 404, "not found")
        end
      end)

      change = insert_change!()

      {:ok, claim} = ReconstructionJob.claim(actor: ctx.worker)
      assert claim.change_id == change.id

      Map.merge(ctx, %{change: change, claim: claim})
    end

    test "accepts multipart zip, returns 200 with succeeded payload", ctx do
      zip_path = write_temp_zip()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.jwt)
        |> put_req_header("x-lease-token", ctx.claim.lease_token)
        |> post("/api/worker/reconstruction_jobs/#{ctx.claim.job_id}/result", %{
          "comparison_zip" => %Plug.Upload{
            path: zip_path,
            filename: "comparison.zip",
            content_type: "application/zip"
          }
        })

      assert conn.status == 200
      assert %{"result" => "succeeded"} = json_response_decode(conn)

      assert_enqueued worker: Tracker.Nixpkgs.ChangeArtifactRefreshWorker,
                      args: %{number: ctx.change.number, reason: "merged"}
    end

    test "rejects missing X-Lease-Token with 400", ctx do
      zip_path = write_temp_zip()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.jwt)
        |> post("/api/worker/reconstruction_jobs/#{ctx.claim.job_id}/result", %{
          "comparison_zip" => %Plug.Upload{
            path: zip_path,
            filename: "comparison.zip",
            content_type: "application/zip"
          }
        })

      assert conn.status == 400
      assert %{"error" => "missing_lease_token"} = json_response_decode(conn)
    end

    test "rejects missing comparison_zip field with 400", ctx do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.jwt)
        |> put_req_header("x-lease-token", ctx.claim.lease_token)
        |> post("/api/worker/reconstruction_jobs/#{ctx.claim.job_id}/result", %{})

      assert conn.status == 400
      assert %{"error" => "missing_comparison_zip"} = json_response_decode(conn)
    end

    test "non-worker bearer is rejected with 403 before reaching the controller", ctx do
      {:ok, plain} =
        User.create_service_account(
          "plain-#{System.unique_integer([:positive])}",
          [:user],
          authorize?: false
        )

      {:ok, %{token: jwt}} = ApiToken.issue(plain.id, %{label: "test"}, actor: plain)
      zip_path = write_temp_zip()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> jwt)
        |> put_req_header("x-lease-token", ctx.claim.lease_token)
        |> post("/api/worker/reconstruction_jobs/#{ctx.claim.job_id}/result", %{
          "comparison_zip" => %Plug.Upload{
            path: zip_path,
            filename: "comparison.zip",
            content_type: "application/zip"
          }
        })

      assert conn.status == 403
    end
  end

  defp json_response_decode(conn) do
    conn.resp_body |> Jason.decode!()
  end

  defp insert_change! do
    attrs = %{
      number: System.unique_integer([:positive]) + 2_000_000,
      title: "test",
      state: :merged,
      author: "tester",
      url: "https://github.com/NixOS/nixpkgs/pull/0",
      processing_status: :artifact_expired,
      merge_commit_sha: "result-test",
      merged_at: ~U[2026-04-01 00:00:00Z]
    }

    id_map = Change.bulk_upsert_all([attrs])
    Ash.get!(Change, id_map[attrs.number])
  end

  defp write_temp_zip do
    changed_paths =
      Jason.encode!(%{
        "attrdiff" => %{"added" => ["pkg"], "changed" => [], "removed" => []}
      })

    {:ok, {_, body}} =
      :zip.create(~c"c.zip", [{~c"changed-paths.json", changed_paths}], [:memory])

    path = Path.join(System.tmp_dir!(), "comparison-#{System.unique_integer([:positive])}.zip")
    File.write!(path, body)
    path
  end
end
