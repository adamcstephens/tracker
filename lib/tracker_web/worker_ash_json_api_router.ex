defmodule TrackerWeb.WorkerAshJsonApiRouter do
  @moduledoc """
  AshJsonApi router for endpoints intended to be called by external service
  accounts (workers), separate from the user-facing `TrackerWeb.AshJsonApiRouter`.

  Mounted behind `:api_reconstruction_worker` (bearer auth + role check) in
  `TrackerWeb.Router`.
  """
  use AshJsonApi.Router,
    domains: [Tracker.Nixpkgs],
    open_api: "/open_api"
end
