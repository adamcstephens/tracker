defmodule Tracker.GitHub.RateLimitCache do
  @moduledoc """
  ETS-based cache for the GitHub API rate limit reset timestamp.

  When any job encounters a rate limit error, it stores the reset
  timestamp. Subsequent jobs check the cache and snooze immediately
  instead of making redundant API calls.
  """

  use GenServer

  @default_table __MODULE__

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
  Checks whether we're currently rate-limited.

  Returns `:ok` if not limited, or `{:limited, seconds}` with the
  number of seconds remaining until the rate limit resets.
  """
  def check(table \\ @default_table) do
    case :ets.lookup(table, :reset_at) do
      [{:reset_at, reset_at}] ->
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
  Stores the rate limit reset timestamp (unix seconds).
  """
  def set_reset(table \\ @default_table, reset_at) do
    :ets.insert(table, {:reset_at, reset_at})
    :ok
  end

  @impl GenServer
  def init(opts) do
    table = Keyword.get(opts, :table, @default_table)
    new(table)
    {:ok, %{table: table}}
  end
end
