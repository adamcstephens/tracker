defmodule Tracker.GitHub.RateLimitCacheTest do
  use ExUnit.Case, async: true

  alias Tracker.GitHub.RateLimitCache

  setup do
    table = :"rate_limit_cache_#{System.unique_integer([:positive])}"
    RateLimitCache.new(table)
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
    %{table: table}
  end

  describe "check/1" do
    test "returns :ok when no rate limit is cached", %{table: table} do
      assert :ok = RateLimitCache.check(table)
    end

    test "returns {:limited, seconds} when rate limit is active", %{table: table} do
      reset_at = System.os_time(:second) + 300
      RateLimitCache.set_reset(table, reset_at)

      assert {:limited, seconds} = RateLimitCache.check(table)
      assert seconds > 0
      assert seconds <= 300
    end

    test "returns :ok when cached reset time is in the past", %{table: table} do
      reset_at = System.os_time(:second) - 10
      RateLimitCache.set_reset(table, reset_at)

      assert :ok = RateLimitCache.check(table)
    end
  end

  describe "set_reset/2" do
    test "overwrites previous reset time", %{table: table} do
      RateLimitCache.set_reset(table, System.os_time(:second) + 100)
      RateLimitCache.set_reset(table, System.os_time(:second) + 500)

      assert {:limited, seconds} = RateLimitCache.check(table)
      assert seconds > 100
    end
  end
end
