defmodule TrackerWeb.FeedLink do
  @moduledoc """
  Shared helpers for a user's private notifications Atom feed link, used by the
  inbox and account settings. The path is host-relative so feed readers resolve
  it against the host the user actually visited, rather than the endpoint's
  configured URL.
  """
  use TrackerWeb, :verified_routes

  alias Tracker.Accounts.User

  @doc "Mint a feed token for the user if they don't have one yet."
  def ensure_token(%{feed_token: nil} = user) do
    case User.rotate_feed_token(user, actor: user) do
      {:ok, updated} -> updated
      _ -> user
    end
  end

  def ensure_token(user), do: user

  @doc "The host-relative feed path, or `nil` when the user has no token."
  def path(%{feed_token: nil}), do: nil
  def path(%{feed_token: token}), do: ~p"/feeds/notifications/#{token}"
end
