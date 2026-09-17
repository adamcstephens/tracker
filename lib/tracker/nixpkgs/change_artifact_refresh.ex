defmodule Tracker.Nixpkgs.ChangeArtifactRefresh do
  @moduledoc """
  Loads package-link refresh diagnostics and enqueues administrator retries.
  """

  import Ecto.Query

  alias Tracker.Accounts.User
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactRefreshWorker
  alias Tracker.Repo

  @incomplete_states Oban.Job.unique_states(:incomplete)
  @incomplete_state_names Enum.map(@incomplete_states, &to_string/1)

  defmodule Diagnostics do
    use TypedStruct

    typedstruct enforce: true do
      field :id, pos_integer()
      field :reason, String.t()
      field :state, String.t()
      field :attempt, non_neg_integer()
      field :max_attempts, pos_integer()
      field :inserted_at, DateTime.t()
      field :scheduled_at, DateTime.t()
      field :attempted_at, DateTime.t() | nil
      field :completed_at, DateTime.t() | nil
      field :discarded_at, DateTime.t() | nil
      field :cancelled_at, DateTime.t() | nil
      field :initiated_by_user_id, String.t() | nil
      field :initiated_by_github_username, String.t() | nil
      field :raw_error, String.t() | nil
      field :incomplete?, boolean()
    end
  end

  def latest(number) when is_integer(number) do
    worker = Oban.Worker.to_string(ChangeArtifactRefreshWorker)
    reasons = ["merged", "head_sha_changed"]

    from(job in Oban.Job,
      where: job.worker == ^worker,
      where: job.args["number"] == ^number,
      where: job.args["reason"] in ^reasons,
      order_by: [desc: job.inserted_at, desc: job.id],
      limit: 1
    )
    |> Repo.one()
    |> to_diagnostics()
  end

  def retry(%Change{} = change, %User{} = actor) do
    if User.has_role?(actor, :admin) do
      enqueue_retry(change, actor)
    else
      {:error, :forbidden}
    end
  end

  def retry(%Change{}, _actor), do: {:error, :forbidden}

  defp enqueue_retry(%Change{state: :merged} = change, %User{} = actor) do
    insert_retry(change, actor, "merged")
  end

  defp enqueue_retry(%Change{state: state} = change, %User{} = actor)
       when state in [:open, :draft] do
    insert_retry(change, actor, "head_sha_changed")
  end

  defp enqueue_retry(%Change{}, %User{}), do: {:error, :unsupported_change_state}

  defp insert_retry(%Change{} = change, %User{} = actor, reason) do
    args = %{
      number: change.number,
      reason: reason,
      initiated_by_user_id: actor.id,
      initiated_by_github_username: actor.github_username
    }

    unique = [
      fields: [:worker, :args],
      keys: [:number, :reason],
      period: :infinity,
      states: @incomplete_states
    ]

    case args |> ChangeArtifactRefreshWorker.new(unique: unique) |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true} = job} ->
        {:ok, :existing, reload_diagnostics(job)}

      {:ok, %Oban.Job{} = job} ->
        {:ok, :enqueued, reload_diagnostics(job)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reload_diagnostics(%Oban.Job{} = job) do
    Oban.Job
    |> Repo.get!(job.id)
    |> to_diagnostics()
  end

  defp to_diagnostics(nil), do: nil

  defp to_diagnostics(%Oban.Job{} = job) do
    %Diagnostics{
      id: job.id,
      reason: arg(job.args, "reason"),
      state: job.state,
      attempt: job.attempt,
      max_attempts: job.max_attempts,
      inserted_at: job.inserted_at,
      scheduled_at: job.scheduled_at,
      attempted_at: job.attempted_at,
      completed_at: job.completed_at,
      discarded_at: job.discarded_at,
      cancelled_at: job.cancelled_at,
      initiated_by_user_id: arg(job.args, "initiated_by_user_id"),
      initiated_by_github_username: arg(job.args, "initiated_by_github_username"),
      raw_error: latest_error(job.errors),
      incomplete?: job.state in @incomplete_state_names
    }
  end

  defp arg(args, key), do: Map.get(args, key) || Map.get(args, String.to_existing_atom(key))

  defp latest_error([]), do: nil

  defp latest_error(errors) do
    errors
    |> List.last()
    |> Map.get("error")
  end
end
