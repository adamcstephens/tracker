defmodule Tracker.Repo do
  use AshSqlite.Repo,
    otp_app: :tracker
end
