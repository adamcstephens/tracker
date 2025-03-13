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
    fetch_channel(channel)
    |> write_to_database()
  end

  def fetch_channel(channel) do
    # get the redirected URL so we are consistent across queries
    [base_url] =
      Req.get!("https://channels.nixos.org/#{channel}", redirect: false).headers["location"]

    revision = Req.get!(base_url <> "/git-revision").body

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
        batch_size: 15000,
        upsert?: true,
        upsert_identity: :unique_attribute,
        upsert_fields: :updated_at
      )

    if bulk_status == :error do
      Logger.error("Failed to load channel #{channel} at #{revision}")
    end

    channel_revision
    |> Ash.Changeset.for_update(:record_result, %{result: bulk_status})
    |> Ash.update!()

    bulk_status
  end
end
