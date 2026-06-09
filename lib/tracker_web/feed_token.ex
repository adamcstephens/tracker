defmodule TrackerWeb.FeedToken do
  @moduledoc """
  Signs and verifies the stateless token embedded in a user's personal
  notifications-feed URL. Feed readers can't do OAuth, so the token *is* the
  credential — but it only ever grants reading that one user's notification
  ledger.

  The signed payload carries the user id plus the user's `feed_token_seed`.
  Verification reloads the user and requires the seed to still match, so
  `User.rotate_feed_token` invalidates any outstanding feed URL.
  """

  alias Tracker.Accounts.User

  @salt "notifications-feed"

  @doc "Signs a feed token for `user`."
  @spec sign(User.t()) :: String.t()
  def sign(%User{} = user) do
    Phoenix.Token.sign(TrackerWeb.Endpoint, @salt, %{
      user_id: user.id,
      seed: user.feed_token_seed
    })
  end

  @doc """
  Verifies a feed token, returning the owning user when the token is valid and
  its seed still matches the user's current `feed_token_seed`.
  """
  @spec verify(String.t()) :: {:ok, User.t()} | {:error, atom()}
  def verify(token) when is_binary(token) do
    with {:ok, %{user_id: user_id, seed: seed}} <-
           Phoenix.Token.verify(TrackerWeb.Endpoint, @salt, token, max_age: :infinity),
         {:ok, %User{} = user} <- Ash.get(User, user_id, authorize?: false),
         true <- seed == user.feed_token_seed do
      {:ok, user}
    else
      false -> {:error, :stale_token}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_token}
    end
  end

  def verify(_token), do: {:error, :invalid_token}
end
