defmodule TrackerWeb.NotificationPresenter do
  @moduledoc """
  Render-on-read presentation for `Tracker.Notifications.Notification` records,
  shared by the in-app inbox and the per-user Atom feed. Expects the
  notification's references (package/channel/change/...) to be loaded.
  """
  use TrackerWeb, :verified_routes

  @doc "A one-line human description of a notification."
  def describe(%{type: :channel_revision_published} = n),
    do: "New revision published on #{channel_name(n)}"

  def describe(%{type: :package_added} = n),
    do: "#{package_name(n)} added to #{channel_name(n)}"

  def describe(%{type: :package_removed} = n),
    do: "#{package_name(n)} removed from #{channel_name(n)}"

  def describe(%{type: :package_version_changed} = n),
    do: "#{package_name(n)} updated on #{channel_name(n)}"

  def describe(%{type: :change_propagated} = n) do
    case n.channel do
      nil -> "Change ##{change_number(n)} propagated"
      channel -> "Change ##{change_number(n)} reached #{channel.name}"
    end
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

  defp channel_name(%{channel: %{name: name}}), do: name
  defp channel_name(_), do: "a channel"

  defp package_name(%{package: %{attribute: attribute}}), do: attribute
  defp package_name(_), do: "a package"

  defp change_number(%{change: %{number: number}}), do: number
  defp change_number(_), do: nil
end
