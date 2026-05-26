defmodule Mix.Tasks.Tracker.ApiToken.Support do
  @moduledoc false

  alias Tracker.Accounts.User

  require Ash.Query

  @doc """
  Resolves a user from a `github_username`, including the `service:<name>`
  sentinel form used by service accounts. Raises via `Mix.raise/1` on miss.
  """
  def fetch_user_by_github_username!(nil), do: Mix.raise("missing --actor")

  def fetch_user_by_github_username!(github_username) when is_binary(github_username) do
    User
    |> Ash.Query.filter(github_username == ^github_username)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %User{} = user} -> user
      _ -> Mix.raise("no user found with github_username=#{inspect(github_username)}")
    end
  end

  @doc """
  Resolves a user by id (UUID) or `github_username`.
  """
  def fetch_user!(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} ->
        case Ash.get(User, id, authorize?: false) do
          {:ok, %User{} = user} -> user
          _ -> Mix.raise("no user found with id=#{inspect(value)}")
        end

      :error ->
        fetch_user_by_github_username!(value)
    end
  end
end
