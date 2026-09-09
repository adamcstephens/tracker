defmodule Tracker.TimeZone do
  @utc "Etc/UTC"
  @reference ~U[2026-01-01 00:00:00Z]

  def default, do: @utc

  def valid?(time_zone) when is_binary(time_zone) do
    match?({:ok, _}, DateTime.shift_zone(@reference, time_zone))
  end

  def valid?(_time_zone), do: false

  def shift!(datetime, time_zone) do
    {:ok, datetime} = DateTime.shift_zone(datetime, time_zone)
    datetime
  end
end
