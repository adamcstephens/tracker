ExUnit.start(exclude: [:playwright])

if :playwright in ExUnit.configuration()[:include] do
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
  Application.put_env(:phoenix_test, :base_url, TrackerWeb.Endpoint.url())
end

Ecto.Adapters.SQL.Sandbox.mode(Tracker.Repo, :manual)
