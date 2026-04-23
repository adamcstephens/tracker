defmodule Tracker.GitHub.RateLimitCacheTest do
  use ExUnit.Case, async: true

  alias Tracker.GitHub.RateLimitCache

  setup do
    table = :"rate_limit_cache_#{System.unique_integer([:positive])}"
    RateLimitCache.new(table)
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
    %{table: table}
  end

  describe "check/2" do
    test "returns :ok when no rate limit is cached for the bucket", %{table: table} do
      assert :ok = RateLimitCache.check(:rest, table)
      assert :ok = RateLimitCache.check(:graphql, table)
    end

    test "returns {:limited, seconds} when bucket has an active reset", %{table: table} do
      reset_at = System.os_time(:second) + 300
      RateLimitCache.set_reset(:rest, reset_at, table)

      assert {:limited, seconds} = RateLimitCache.check(:rest, table)
      assert seconds > 0
      assert seconds <= 300
    end

    test "returns :ok when the bucket's reset time is in the past", %{table: table} do
      reset_at = System.os_time(:second) - 10
      RateLimitCache.set_reset(:rest, reset_at, table)

      assert :ok = RateLimitCache.check(:rest, table)
    end

    test "rest and graphql buckets are independent", %{table: table} do
      reset_at = System.os_time(:second) + 300
      RateLimitCache.set_reset(:rest, reset_at, table)

      assert {:limited, _} = RateLimitCache.check(:rest, table)
      assert :ok = RateLimitCache.check(:graphql, table)

      RateLimitCache.set_reset(:graphql, reset_at, table)
      assert {:limited, _} = RateLimitCache.check(:graphql, table)
    end
  end

  describe "set_reset/3" do
    test "overwrites previous reset time for the same bucket", %{table: table} do
      RateLimitCache.set_reset(:rest, System.os_time(:second) + 100, table)
      RateLimitCache.set_reset(:rest, System.os_time(:second) + 500, table)

      assert {:limited, seconds} = RateLimitCache.check(:rest, table)
      assert seconds > 100
    end

    test "setting one bucket does not affect the other", %{table: table} do
      RateLimitCache.set_reset(:rest, System.os_time(:second) + 500, table)
      RateLimitCache.set_reset(:graphql, System.os_time(:second) + 100, table)

      assert {:limited, rest_s} = RateLimitCache.check(:rest, table)
      assert {:limited, graphql_s} = RateLimitCache.check(:graphql, table)
      assert rest_s > graphql_s
    end
  end
end
