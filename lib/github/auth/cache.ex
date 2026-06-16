defmodule GitHub.Auth.Cache do
  @moduledoc """
  ETS-backed cache for short-lived GitHub auth tokens (app JWTs and
  installation access tokens).

  Entries carry a Unix expiration timestamp and are purged both lazily on
  read and periodically. Keys are conventionally `{:app, app_id}` or
  `{:installation, installation_id}`, but any term works.
  """

  use GenServer

  @ets_table __MODULE__
  @remove_expired_cycle_msec 60_000

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Returns `{:ok, value}` for an unexpired entry, or `:error` if missing,
  expired, or the cache is not running.
  """
  @spec get(term()) :: {:ok, term()} | :error
  def get(key) do
    case :ets.whereis(@ets_table) do
      :undefined -> :error
      _ -> lookup(key)
    end
  end

  @doc """
  Stores `value` under `key` until the `expiration` Unix timestamp (seconds).
  """
  @spec put(term(), integer(), term()) :: :ok
  def put(key, expiration, value) do
    GenServer.call(__MODULE__, {:put, key, expiration, value})
  end

  @impl GenServer
  def init(nil) do
    :ets.new(@ets_table, [:named_table, :protected, read_concurrency: true])
    schedule_cleanup()
    {:ok, nil}
  end

  @impl GenServer
  def handle_call({:put, key, expiration, value}, _from, state) do
    :ets.insert(@ets_table, {key, expiration, value})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:remove_expired, state) do
    :ets.select_delete(@ets_table, [{{:_, :"$1", :_}, [{:<, :"$1", now()}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp lookup(key) do
    case :ets.lookup(@ets_table, key) do
      [{^key, expiration, value}] when expiration > 0 ->
        if expiration > now(), do: {:ok, value}, else: :error

      _ ->
        :error
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :remove_expired, @remove_expired_cycle_msec)
  end

  defp now, do: System.os_time(:second)
end
