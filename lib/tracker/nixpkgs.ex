defmodule Tracker.Nixpkgs do
  use Ash.Domain,
    otp_app: :tracker

  require Logger

  resources do
    resource Tracker.Nixpkgs.Package
    resource Tracker.Nixpkgs.PackageRevision
    resource Tracker.Nixpkgs.ChannelRevision
  end

  def load_all_channels() do
    Application.get_env(:tracker, :channels, []) |> Enum.each(&load_channel(&1))
  end

  def load_channel(channel \\ "nixos-unstable") do
    {revision, base_url} = get_channel_revision(channel)

    case Tracker.Nixpkgs.ChannelRevision.find(channel, revision) do
      {:ok, %Tracker.Nixpkgs.ChannelRevision{result: :success}} ->
        :ok

      {:ok, %Tracker.Nixpkgs.ChannelRevision{}} ->
        fetch_channel(channel, revision, base_url)
        |> write_to_database()

      {:error, %Ash.Error.Query.NotFound{}} ->
        fetch_channel(channel, revision, base_url)
        |> write_to_database()
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
      |> Ash.bulk_create(Tracker.Nixpkgs.Package, :load,
        batch_size: 25,
        upsert?: true,
        upsert_identity: :unique_attribute,
        upsert_fields: :updated_at
      )
      |> dbg()

    if bulk_status == :error do
      Logger.error("Failed to load channel #{channel} at #{revision}")
    end

    channel_revision
    |> Ash.Changeset.for_update(:record_result, %{result: bulk_status})
    |> Ash.update!()
  end
end
