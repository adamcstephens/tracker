defmodule TrackerWeb.NotificationPresenter.TypeMeta do
  @moduledoc "Display metadata for one notification type."
  use TypedStruct

  typedstruct enforce: true do
    field :label, String.t()
    field :filter_label, String.t()
    field :class, String.t()
  end
end

defmodule TrackerWeb.NotificationPresenter do
  @moduledoc """
  Render-on-read presentation for `Tracker.Notifications.Notification` records,
  shared by the in-app inbox and the per-user Atom feed. Expects the
  notification's references (package/channel/change/...) to be loaded.
  """
  use TrackerWeb, :verified_routes

  alias Tracker.Nixpkgs.PackageHistory
  alias TrackerWeb.NotificationPresenter.TypeMeta

  # Display order for filters and summaries.
  @type_order [
    :package_version_changed,
    :change_propagated,
    :package_added,
    :package_removed,
    :channel_revision_published
  ]

  @type_meta %{
    package_version_changed: %TypeMeta{label: "Updated", filter_label: "Updates", class: "update"},
    change_propagated: %TypeMeta{
      label: "Propagated",
      filter_label: "Propagated",
      class: "propagate"
    },
    package_added: %TypeMeta{label: "Added", filter_label: "Added", class: "add"},
    package_removed: %TypeMeta{label: "Removed", filter_label: "Removed", class: "remove"},
    channel_revision_published: %TypeMeta{
      label: "Revision",
      filter_label: "Revisions",
      class: "revision"
    }
  }

  @doc "All notification types in display order."
  def type_order, do: @type_order

  @doc "The short status label for a type (row chip)."
  def type_label(type), do: Map.fetch!(@type_meta, type).label

  @doc "The plural label for a type (filter chip)."
  def type_filter_label(type), do: Map.fetch!(@type_meta, type).filter_label

  @doc "The CSS modifier carrying the type's accent color."
  def type_class(type), do: Map.fetch!(@type_meta, type).class

  @doc """
  Resolves the old→new version bump for each `:package_version_changed`
  notification on a page, in one batched span reconstruction. Returns
  a map of notification id to `{old_version, new_version}`, with entries
  only where both versions resolve; `hero/2` and `describe/2` fall back to
  the version-less copy for the rest.
  """
  def version_changes(notifications) do
    targets =
      for %{
            type: :package_version_changed,
            package_id: package_id,
            channel_revision: %{id: rev_id, previous_channel_revision_id: prev_id}
          } = n <- notifications,
          not is_nil(package_id) and not is_nil(prev_id) do
        {n.id, package_id, rev_id, prev_id}
      end

    versions = versions_by_package_and_revision(targets)

    for {id, package_id, rev_id, prev_id} <- targets,
        old = versions[{package_id, prev_id}],
        new = versions[{package_id, rev_id}],
        into: %{} do
      {id, {old, new}}
    end
  end

  defp versions_by_package_and_revision([]), do: %{}

  defp versions_by_package_and_revision(targets) do
    revision_ids =
      targets |> Enum.flat_map(fn {_id, _pkg, rev, prev} -> [rev, prev] end) |> Enum.uniq()

    package_ids = targets |> Enum.map(fn {_id, pkg, _rev, _prev} -> pkg end) |> Enum.uniq()

    PackageHistory.versions_at_revisions(revision_ids, package_ids)
  end

  @doc """
  The row's leading identifier: the package attribute (with its version
  bump when resolved via `version_changes/1`), the short revision hash,
  or — for propagations — the change title rendered verbatim (titles
  are free-form; never parsed for versions).
  """
  def hero(n, version_changes \\ %{})

  def hero(%{type: :change_propagated} = n, _version_changes) do
    change_title(n) || "PR ##{change_number(n)}"
  end

  def hero(%{type: :channel_revision_published} = n, _version_changes) do
    case revision_hash(n) do
      nil -> "New revision"
      hash -> "New revision #{hash}"
    end
  end

  def hero(%{type: :package_version_changed} = n, version_changes) do
    case Map.get(version_changes, n.id) do
      {old, new} -> "#{package_name(n)} #{old} → #{new}"
      nil -> package_name(n)
    end
  end

  def hero(n, _version_changes), do: package_name(n)

  @doc "A compact relative timestamp, e.g. `7m ago`."
  def relative_time(occurred_at, now) do
    minutes = DateTime.diff(now, occurred_at, :minute)

    cond do
      minutes < 1 -> "just now"
      minutes < 60 -> "#{minutes}m ago"
      minutes < 1440 -> "#{div(minutes, 60)}h ago"
      true -> "#{div(minutes, 1440)}d ago"
    end
  end

  @doc "The absolute UTC clock time, used as the relative time's tooltip."
  def clock_utc(occurred_at), do: Calendar.strftime(occurred_at, "%H:%M UTC")

  @doc ~S(The day-group label for a timestamp: "Today", "Yesterday", or "Friday, Jun 5".)
  def day_bucket(occurred_at, now) do
    case Date.diff(DateTime.to_date(now), DateTime.to_date(occurred_at)) do
      diff when diff <= 0 -> "Today"
      1 -> "Yesterday"
      _ -> Calendar.strftime(occurred_at, "%A, %b %-d")
    end
  end

  @doc "Groups notifications into `{day_label, notifications}` pairs, preserving order."
  def group_by_day(notifications, now) do
    notifications
    |> Enum.chunk_by(&day_bucket(&1.occurred_at, now))
    |> Enum.map(fn [first | _] = group -> {day_bucket(first.occurred_at, now), group} end)
  end

  @doc """
  A one-line human description of a notification, including the version
  bump for updates when resolved via `version_changes/1`.
  """
  def describe(n, version_changes \\ %{})

  def describe(%{type: :channel_revision_published} = n, _version_changes) do
    case revision_hash(n) do
      nil -> "New revision published on #{channel_name(n)}"
      hash -> "New revision #{hash} published on #{channel_name(n)}"
    end
  end

  def describe(%{type: :package_added} = n, _version_changes),
    do: "#{package_name(n)} added to #{channel_name(n)}"

  def describe(%{type: :package_removed} = n, _version_changes),
    do: "#{package_name(n)} removed from #{channel_name(n)}"

  def describe(%{type: :package_version_changed} = n, version_changes) do
    case Map.get(version_changes, n.id) do
      {old, new} -> "#{package_name(n)} #{old} → #{new} on #{channel_name(n)}"
      nil -> "#{package_name(n)} updated on #{channel_name(n)}"
    end
  end

  def describe(%{type: :change_propagated} = n, _version_changes) do
    prefix =
      case change_title(n) do
        nil -> "PR ##{change_number(n)}"
        title -> "#{title} — PR ##{change_number(n)}"
      end

    "#{prefix} reached #{propagation_target(n)}"
  end

  @doc "The in-app path a notification links to, or `nil` when there is no target."
  def path(%{type: :change_propagated} = n), do: ~p"/changes/#{change_number(n)}"

  def path(%{
        type: :channel_revision_published,
        channel: %{name: name},
        channel_revision: %{revision: rev}
      }),
      do: ~p"/channels/#{name}/revisions/#{rev}"

  def path(%{package: %{attribute: attribute}}) when is_binary(attribute),
    do: ~p"/packages/#{attribute}"

  def path(_n), do: nil

  defp revision_hash(%{channel_revision: %{revision: rev}}) when is_binary(rev),
    do: String.slice(rev, 0, 7)

  defp revision_hash(_), do: nil

  defp change_title(%{change: %{title: title}}) when is_binary(title) and title != "", do: title
  defp change_title(_), do: nil

  # The propagation destination: the branch the change reached (a channel-kind
  # branch name doubles as the channel name), falling back to the mapped channel.
  defp propagation_target(%{change_branch: %{branch_name: name}}) when is_binary(name), do: name
  defp propagation_target(%{channel: %{name: name}}) when is_binary(name), do: name
  defp propagation_target(_), do: "a new branch"

  defp channel_name(%{channel: %{name: name}}), do: name
  defp channel_name(_), do: "a channel"

  defp package_name(%{package: %{attribute: attribute}}), do: attribute
  defp package_name(_), do: "a package"

  defp change_number(%{change: %{number: number}}), do: number
  defp change_number(_), do: nil
end
