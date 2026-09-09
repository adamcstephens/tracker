defmodule TrackerWeb.Time do
  alias Tracker.TimeZone

  def format_datetime(datetime, time_zone) do
    datetime
    |> TimeZone.shift!(time_zone)
    |> Calendar.strftime("%Y-%m-%d %H:%M %Z")
  end
end
