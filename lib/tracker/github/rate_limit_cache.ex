defmodule Tracker.GitHub.RateLimitCache do
  @moduledoc """
  ETS-based cache for GitHub API rate limit reset timestamps.

  GitHub tracks REST and GraphQL quotas separately, so entries are keyed
  by bucket (`:rest` or `:graphql`). When any job encounters a rate limit
  error, it stores the reset timestamp for that bucket. Subsequent jobs
  check the cache and snooze immediately instead of making redundant
  API calls.
  """

  use GenServer

  @default_table __MODULE__
  @type bucket :: :rest | :graphql

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Creates a new ETS table for rate limit caching.
  Used directly in tests for isolated tables.
  """
  def new(name \\ @default_table) do
    :ets.new(name, [:set, :public, :named_table])
  end

  @doc """
  Checks whether the given bucket is currently rate-limited.

  Returns `:ok` if not limited, or `{:limited, seconds}` with the
  number of seconds remaining until the rate limit resets.
  """
  @spec check(bucket, atom) :: :ok | {:limited, pos_integer}
  def check(bucket, table \\ @default_table) when bucket in [:rest, :graphql] do
    case :ets.lookup(table, {:reset_at, bucket}) do
      [{{:reset_at, ^bucket}, reset_at}] ->
        remaining = reset_at - System.os_time(:second)

        if remaining > 0 do
          {:limited, remaining}
        else
          :ok
        end

      [] ->
        :ok
    end
  end

  @doc """
  Stores the rate limit reset timestamp (unix seconds) for the given bucket.
  """
  @spec set_reset(bucket, integer, atom) :: :ok
  def set_reset(bucket, reset_at, table \\ @default_table)
      when bucket in [:rest, :graphql] do
    :ets.insert(table, {{:reset_at, bucket}, reset_at})
    :ok
  end

  @impl GenServer
  def init(opts) do
    table = Keyword.get(opts, :table, @default_table)
    new(table)
    {:ok, %{table: table}}
  end
end
