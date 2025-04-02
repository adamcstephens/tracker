defmodule Tracker.Nixpkgs.ChannelWorker do
  use Oban.Worker, queue: :channels, max_attempts: 10

  import Ecto.Query, only: [from: 2]
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel" => channel}}) do
    result = load_channel(channel)

    %{"channel" => channel} |> new(schedule_in: 4 * 60 * 60) |> Oban.insert!()

    result
  end

  def start_all_channels() do
    Application.get_env(:tracker, :channels, [])
    |> Enum.filter(&(not channel_job_running?(&1)))
    |> Enum.each(fn channel ->
      %{"channel" => channel} |> Tracker.Nixpkgs.ChannelWorker.new() |> Oban.insert()
    end)
  end

  def load_channel(channel \\ "nixos-unstable") do
    {revision, base_url} = get_channel_revision(channel)

    case Tracker.Nixpkgs.ChannelRevision.find(channel, revision) do
      {:ok, %Tracker.Nixpkgs.ChannelRevision{result: :success}} ->
        :ok

      {:ok, %Tracker.Nixpkgs.ChannelRevision{result: :partial_success}} ->
        :ok

      _ ->
        fetch_channel(channel, revision, base_url)
        |> write_to_database()
    end
  end

  def channel_job_running?(channel) do
    query =
      from j in Oban.Job,
        where: j.state != "cancelled",
        where: j.state != "discarded",
        where: j.state != "completed",
        where: j.args["channel"] == ^channel

    case Tracker.Repo.one(query) do
      nil -> false
      _ -> true
    end
  end

  def get_channel_revision(channel) do
    # get the redirected URL so we are consistent across queries
    [base_url] =
      Req.get!("https://channels.nixos.org/#{channel}", redirect: false).headers["location"]

    revision = Req.get!(base_url <> "/git-revision").body

    {revision, base_url}
  end

  def fetch_channel(channel, revision, base_url) do
    Req.get!(base_url <> "/packages.json.br", raw: true).body
    |> ExBrotli.decompress!()
    |> :json.decode()
    |> Map.put("revision", revision)
    |> Map.put("channel", channel)
  end

  def queue_packages(_) do
    {:cancel, :unsupported_structure}
  end

  def write_to_database(%{
        "packages" => packages,
        "version" => 2,
        "revision" => revision,
        "channel" => channel
      }) do
    packages =
      case Application.get_env(:tracker, :loader_limit) do
        nil -> packages
        limit -> Enum.take(packages, limit)
      end

    channel_revision =
      Tracker.Nixpkgs.ChannelRevision
      |> Ash.Changeset.for_create(:create, %{revision: revision, channel: channel})
      |> Ash.create!()

    %{status: bulk_status} =
      packages
      |> Enum.map(fn {package, info} ->
        %{
          attribute: package,
          revision: %{version: info["version"], channel_revision_id: channel_revision.id}
        }
      end)
      |> Ash.bulk_create(Tracker.Nixpkgs.Package, :load, batch_size: 1000)

    if bulk_status == :error do
      Logger.error("Failed to load channel #{channel} at #{revision}")
    end

    channel_revision
    |> Ash.Changeset.for_update(:record_result, %{result: bulk_status})
    |> Ash.update!()

    bulk_status
  end
end
