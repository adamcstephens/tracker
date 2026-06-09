defmodule TrackerWeb.NotificationPresenter do
  @moduledoc """
  Render-on-read presentation for `Tracker.Notifications.Notification` records,
  shared by the in-app inbox and the per-user Atom feed. Expects the
  notification's references (package/channel/change/...) to be loaded.
  """
  use TrackerWeb, :verified_routes

  @doc "A one-line human description of a notification."
  def describe(%{type: :channel_revision_published} = n) do
    case revision_hash(n) do
      nil -> "New revision published on #{channel_name(n)}"
      hash -> "New revision #{hash} published on #{channel_name(n)}"
    end
  end

  def describe(%{type: :package_added} = n),
    do: "#{package_name(n)} added to #{channel_name(n)}"

  def describe(%{type: :package_removed} = n),
    do: "#{package_name(n)} removed from #{channel_name(n)}"

  def describe(%{type: :package_version_changed} = n),
    do: "#{package_name(n)} updated on #{channel_name(n)}"

  def describe(%{type: :change_propagated} = n) do
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
