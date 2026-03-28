defmodule Tracker.Nixpkgs.ChannelWorker do
  use Oban.Worker, queue: :channels, max_attempts: 10

  import Ecto.Query, only: [from: 2]
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel" => channel}}) do
    result = load_channel(channel)

    %{"channel" => channel} |> new(schedule_in: 4 * 60 * 60) |> Oban.insert!()

    case result do
      :ok -> :ok
      :success -> :ok
      :partial_success -> :ok
      :error -> {:error, :load_failed}
      {:error, reason} -> {:error, reason}
    end
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
        "version" => version,
        "revision" => revision,
        "channel" => channel
      })
      when version in [2, "2"] do
    packages =
      case Application.get_env(:tracker, :loader_limit) do
        nil -> packages
        limit -> Enum.take(packages, limit)
      end

    channel_revision =
      Tracker.Nixpkgs.ChannelRevision
      |> Ash.Changeset.for_create(:create, %{revision: revision, channel: channel})
      |> Ash.create!()

    # Slim down to only what we need: %{attribute => version}
    # Filter out packages with empty versions (wrappers, meta-packages, etc.)
    packages =
      packages
      |> Map.new(fn {attr, info} -> {attr, info["version"]} end)
      |> Map.reject(fn {_attr, version} -> version == "" end)

    bulk_status = load_packages(packages, channel_revision)

    if bulk_status != :success do
      Logger.error("Failed to load channel #{channel} at #{revision}")
    end

    channel_revision
    |> Ash.Changeset.for_update(:record_result, %{result: bulk_status})
    |> Ash.update!()

    bulk_status
  end

  def write_to_database(%{"version" => version}) do
    Logger.error("Unsupported packages.json version: #{inspect(version)}")
    {:error, :unsupported_version}
  end

  @chunk_size 10_000

  # packages is %{attribute => version} (already slimmed)
  defp load_packages(packages, channel_revision) do
    # Step 1: Bulk upsert packages in chunks (no relationship management)
    pkg_status =
      packages
      |> Stream.map(fn {attribute, _version} -> %{attribute: attribute} end)
      |> Stream.chunk_every(@chunk_size)
      |> Enum.reduce(:success, fn chunk, acc ->
        %{status: status} =
          Ash.bulk_create(chunk, Tracker.Nixpkgs.Package, :bulk_upsert,
            batch_size: 5000,
            return_errors?: true
          )

        worst_status(acc, status)
      end)

    if pkg_status == :error do
      :error
    else
      # Step 2: Build attribute -> id lookup map via raw SQL (memory efficient)
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(Tracker.Repo, "SELECT attribute, id FROM packages")

      id_map = Map.new(rows, fn [attribute, id] -> {attribute, id} end)

      # Step 3: Bulk create package revisions in chunks
      rev_status =
        packages
        |> Stream.map(fn {attribute, version} ->
          %{
            package_id: Map.fetch!(id_map, attribute),
            channel_revision_id: channel_revision.id,
            version: version
          }
        end)
        |> Stream.chunk_every(@chunk_size)
        |> Enum.reduce(:success, fn chunk, acc ->
          %{status: status} =
            Ash.bulk_create(chunk, Tracker.Nixpkgs.PackageRevision, :load,
              batch_size: 5000,
              return_errors?: true
            )

          worst_status(acc, status)
        end)

      worst_status(pkg_status, rev_status)
    end
  end

  defp worst_status(:error, _), do: :error
  defp worst_status(_, :error), do: :error
  defp worst_status(:partial_success, _), do: :partial_success
  defp worst_status(_, :partial_success), do: :partial_success
  defp worst_status(:success, :success), do: :success
end
