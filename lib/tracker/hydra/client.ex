defmodule Tracker.Hydra.Client do
  @moduledoc """
  Client for hydra-related external data sources.

  Currently reads from `prometheus.nixos.org`, the same Prometheus
  exporter that backs https://status.nixos.org/. The exporter scrapes
  hydra.nixos.org and exposes per-channel build/revision state via the
  `channel_revision` and `hydra_job_failed` metrics. Direct calls to
  hydra.nixos.org (eval/build endpoints) would also live in this
  module if and when we need them.

  Test stubbing: pass `plug: {Req.Test, StubName}` via opts.
  """
  use TypedStruct

  @base_url "https://prometheus.nixos.org"
  @user_agent "tracker.robins.wtf"

  defmodule ChannelStatus do
    @moduledoc "One series from the `channel_revision` Prometheus metric."
    use TypedStruct

    typedstruct enforce: true do
      field :channel, String.t()
      field :status, :unmaintained | :stable | :rolling | {:unknown, String.t()}
      field :revision, String.t()
      field :variant, String.t() | nil, enforce: false
      field :current?, boolean()
    end
  end

  defmodule BuildFailure do
    @moduledoc "One series from the `hydra_job_failed` Prometheus metric."
    use TypedStruct

    typedstruct enforce: true do
      field :channel, String.t()
      field :failed?, boolean()
      field :current?, boolean()
      field :project, String.t()
      field :jobset, String.t()
      field :exported_job, String.t()
    end
  end

  @spec fetch_channel_status(keyword) :: {:ok, [ChannelStatus.t()]} | {:error, term()}
  def fetch_channel_status(opts \\ []) do
    with {:ok, series} <- query("channel_revision", opts) do
      {:ok, Enum.map(series, &parse_channel_status/1)}
    end
  end

  @spec fetch_build_failures(keyword) :: {:ok, [BuildFailure.t()]} | {:error, term()}
  def fetch_build_failures(opts \\ []) do
    with {:ok, series} <- query("hydra_job_failed", opts) do
      {:ok, Enum.map(series, &parse_build_failure/1)}
    end
  end

  defp query(promql, opts) do
    req =
      Req.new(
        base_url: @base_url,
        headers: [{"user-agent", @user_agent}],
        retry: false
      )
      |> Req.merge(Keyword.take(opts, [:plug]))

    case Req.get(req, url: "/api/v1/query", params: [query: promql]) do
      {:ok,
       %Req.Response{status: 200, body: %{"status" => "success", "data" => %{"result" => result}}}} ->
        {:ok, result}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_response, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_channel_status(%{"metric" => metric}) do
    %ChannelStatus{
      channel: metric["channel"],
      status: parse_status(metric["status"]),
      revision: metric["revision"],
      variant: metric["variant"],
      current?: metric["current"] == "1"
    }
  end

  defp parse_build_failure(%{"metric" => metric, "value" => [_ts, value]}) do
    %BuildFailure{
      channel: metric["channel"],
      failed?: value == "1",
      current?: metric["current"] == "1",
      project: metric["project"],
      jobset: metric["jobset"],
      exported_job: metric["exported_job"]
    }
  end

  defp parse_status("unmaintained"), do: :unmaintained
  defp parse_status("stable"), do: :stable
  defp parse_status("rolling"), do: :rolling
  defp parse_status(other), do: {:unknown, other}
end
