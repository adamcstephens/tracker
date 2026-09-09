defmodule Tracker.TimeZone do
  @utc "Etc/UTC"
  @reference ~U[2026-01-01 00:00:00Z]

  def default, do: @utc

  def options do
    ["Etc/UTC" | zones_from_tzdata()]
  end

  def valid?(time_zone) when is_binary(time_zone) do
    match?({:ok, _}, DateTime.shift_zone(@reference, time_zone))
  end

  def valid?(_time_zone), do: false

  def shift!(datetime, time_zone) do
    {:ok, datetime} = DateTime.shift_zone(datetime, time_zone)
    datetime
  end

  defp zones_from_tzdata do
    Zoneinfo.tzpath()
    |> Path.join("zone1970.tab")
    |> File.stream!()
    |> Stream.reject(&String.starts_with?(&1, "#"))
    |> Stream.map(fn line ->
      [_locations, _coordinates, time_zone | _] = String.split(line, "\t", trim: true)
      time_zone
    end)
    |> Enum.sort()
  end
end
