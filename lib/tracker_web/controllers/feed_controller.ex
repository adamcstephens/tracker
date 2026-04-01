defmodule TrackerWeb.FeedController do
  use TrackerWeb, :controller

  @base_url "https://tracker-dev.junco.dev"

  def channel(conn, %{"channel" => channel}) do
    revisions =
      Tracker.Nixpkgs.ChannelRevision.list_by_channel!(channel,
        page: [limit: 50]
      ).results

    latest_updated =
      case revisions do
        [rev | _] -> rev.released_at
        [] -> DateTime.utc_now()
      end

    feed =
      Atomex.Feed.new(
        "#{@base_url}/channels/#{channel}",
        latest_updated,
        "#{channel} - Tracker"
      )
      |> Atomex.Feed.link("#{@base_url}/feeds/channels/#{channel}", rel: "self")
      |> Atomex.Feed.link("#{@base_url}/channels/#{channel}", rel: "alternate")
      |> Atomex.Feed.entries(Enum.map(revisions, &channel_entry(channel, &1)))
      |> Atomex.Feed.build()
      |> Atomex.generate_document()

    conn
    |> put_resp_content_type("application/atom+xml")
    |> send_resp(200, feed)
  end

  def package(conn, %{"name" => name} = params) do
    package = Tracker.Nixpkgs.Package.get_by_attribute!(name)
    channel_filter = Map.get(params, "channel", "")

    revisions = load_package_version_changes(package.id, channel_filter)

    latest_updated =
      case revisions do
        [rev | _] -> rev.channel_revision.released_at
        [] -> DateTime.utc_now()
      end

    title =
      if channel_filter != "" do
        "#{name} on #{channel_filter} - Tracker"
      else
        "#{name} - Tracker"
      end

    self_url =
      if channel_filter != "" do
        "#{@base_url}/feeds/packages/#{name}?channel=#{channel_filter}"
      else
        "#{@base_url}/feeds/packages/#{name}"
      end

    feed =
      Atomex.Feed.new(
        "#{@base_url}/packages/#{name}",
        latest_updated,
        title
      )
      |> Atomex.Feed.link(self_url, rel: "self")
      |> Atomex.Feed.link("#{@base_url}/packages/#{name}", rel: "alternate")
      |> Atomex.Feed.entries(Enum.map(revisions, &package_entry(name, &1)))
      |> Atomex.Feed.build()
      |> Atomex.generate_document()

    conn
    |> put_resp_content_type("application/atom+xml")
    |> send_resp(200, feed)
  end

  defp channel_entry(channel, rev) do
    url = "#{@base_url}/channels/#{channel}/revisions/#{rev.revision}"
    short_hash = String.slice(rev.revision, 0, 7)

    Atomex.Entry.new(
      url,
      rev.released_at,
      "#{channel} #{short_hash}"
    )
    |> Atomex.Entry.link(url, rel: "alternate")
    |> Atomex.Entry.published(rev.released_at)
    |> Atomex.Entry.build()
  end

  defp package_entry(name, rev) do
    url =
      "#{@base_url}/channels/#{rev.channel_revision.channel}/revisions/#{rev.channel_revision.revision}"

    Atomex.Entry.new(
      "#{url}##{name}",
      rev.channel_revision.released_at,
      "#{name} #{rev.version} on #{rev.channel_revision.channel}"
    )
    |> Atomex.Entry.link(url, rel: "alternate")
    |> Atomex.Entry.published(rev.channel_revision.released_at)
    |> Atomex.Entry.summary(
      "#{name} updated to #{rev.version} on #{rev.channel_revision.channel}"
    )
    |> Atomex.Entry.build()
  end

  defp load_package_version_changes(package_id, channel_filter) do
    all_revisions = Tracker.Nixpkgs.PackageRevision.version_changes_by_package!(package_id)

    change_ids =
      all_revisions
      |> Enum.group_by(& &1.channel_revision.channel)
      |> Enum.flat_map(fn {_channel, channel_revs} ->
        channel_revs
        |> Enum.reduce({nil, []}, fn rev, {prev_version, acc} ->
          if rev.version != prev_version do
            {rev.version, [rev.id | acc]}
          else
            {prev_version, acc}
          end
        end)
        |> elem(1)
      end)
      |> MapSet.new()

    all_revisions
    |> Enum.filter(&MapSet.member?(change_ids, &1.id))
    |> then(fn revs ->
      if channel_filter != "" do
        Enum.filter(revs, &(&1.channel_revision.channel == channel_filter))
      else
        revs
      end
    end)
    |> Enum.sort_by(& &1.channel_revision.released_at, {:desc, DateTime})
    |> Enum.take(50)
  end
end
