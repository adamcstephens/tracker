defmodule TrackerWeb.TimeTest do
  use ExUnit.Case, async: true

  alias TrackerWeb.Time

  test "formats absolute timestamps in the requested zone across daylight saving time" do
    assert Time.format_datetime(~U[2026-07-01 16:05:00Z], "America/New_York") ==
             "2026-07-01 12:05 EDT"

    assert Time.format_datetime(~U[2026-01-01 16:05:00Z], "America/New_York") ==
             "2026-01-01 11:05 EST"
  end

  test "formats UTC explicitly" do
    assert Time.format_datetime(~U[2026-07-01 16:05:00Z], "Etc/UTC") == "2026-07-01 16:05 UTC"
  end
end
