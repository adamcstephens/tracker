defmodule Tracker.Hydra.ClientTest do
  use ExUnit.Case, async: true

  alias Tracker.Hydra.Client
  alias Tracker.Hydra.Client.BuildFailure
  alias Tracker.Hydra.Client.ChannelStatus

  defp send_prometheus_response(conn, result) do
    body =
      Jason.encode!(%{
        "status" => "success",
        "data" => %{"resultType" => "vector", "result" => result}
      })

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end

  describe "fetch_channel_status/1" do
    test "parses channel_revision series into ChannelStatus structs" do
      Req.Test.stub(__MODULE__.Prometheus, fn conn ->
        assert conn.request_path == "/api/v1/query"
        assert URI.decode_query(conn.query_string)["query"] == "channel_revision"
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["tracker.robins.wtf"]

        send_prometheus_response(conn, [
          %{
            "metric" => %{
              "channel" => "nixos-unstable",
              "status" => "rolling",
              "revision" => "abc123",
              "variant" => "primary",
              "current" => "1"
            },
            "value" => [1_779_202_039.755, "1"]
          },
          %{
            "metric" => %{
              "channel" => "nixos-25.05",
              "status" => "unmaintained",
              "revision" => "def456",
              "variant" => "primary",
              "current" => "0"
            },
            "value" => [1_779_202_039.755, "1"]
          }
        ])
      end)

      assert {:ok, results} = Client.fetch_channel_status(plug: {Req.Test, __MODULE__.Prometheus})

      assert [
               %ChannelStatus{
                 channel: "nixos-unstable",
                 status: :rolling,
                 revision: "abc123",
                 variant: "primary",
                 current?: true
               },
               %ChannelStatus{
                 channel: "nixos-25.05",
                 status: :unmaintained,
                 revision: "def456",
                 variant: "primary",
                 current?: false
               }
             ] = results
    end

    test "tolerates missing variant label (e.g. nixpkgs-unstable)" do
      Req.Test.stub(__MODULE__.Prometheus, fn conn ->
        send_prometheus_response(conn, [
          %{
            "metric" => %{
              "channel" => "nixpkgs-unstable",
              "status" => "rolling",
              "revision" => "deadbeef",
              "current" => "1"
            },
            "value" => [1_779_202_039.755, "1"]
          }
        ])
      end)

      assert {:ok, [%ChannelStatus{channel: "nixpkgs-unstable", variant: nil}]} =
               Client.fetch_channel_status(plug: {Req.Test, __MODULE__.Prometheus})
    end

    test "returns an error when prometheus returns a non-success status" do
      Req.Test.stub(__MODULE__.Prometheus, fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      assert {:error, _} = Client.fetch_channel_status(plug: {Req.Test, __MODULE__.Prometheus})
    end
  end

  describe "fetch_build_failures/1" do
    test "parses hydra_job_failed series into BuildFailure structs" do
      Req.Test.stub(__MODULE__.Prometheus, fn conn ->
        assert conn.request_path == "/api/v1/query"
        assert URI.decode_query(conn.query_string)["query"] == "hydra_job_failed"

        send_prometheus_response(conn, [
          %{
            "metric" => %{
              "channel" => "nixpkgs-unstable",
              "current" => "1",
              "project" => "nixpkgs",
              "jobset" => "unstable",
              "exported_job" => "unstable"
            },
            "value" => [1_779_202_122.884, "1"]
          },
          %{
            "metric" => %{
              "channel" => "nixos-25.11",
              "current" => "1",
              "project" => "nixos",
              "jobset" => "release-25.11",
              "exported_job" => "tested"
            },
            "value" => [1_779_202_122.884, "0"]
          }
        ])
      end)

      assert {:ok, results} = Client.fetch_build_failures(plug: {Req.Test, __MODULE__.Prometheus})

      assert [
               %BuildFailure{
                 channel: "nixpkgs-unstable",
                 failed?: true,
                 current?: true,
                 project: "nixpkgs",
                 jobset: "unstable",
                 exported_job: "unstable"
               },
               %BuildFailure{
                 channel: "nixos-25.11",
                 failed?: false,
                 current?: true,
                 project: "nixos",
                 jobset: "release-25.11",
                 exported_job: "tested"
               }
             ] = results
    end
  end
end
