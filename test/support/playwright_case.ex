defmodule TrackerWeb.PlaywrightCase do
  @moduledoc """
  Case template for tests that need a real browser.
  """

  use ExUnit.CaseTemplate

  using opts do
    quote do
      use PhoenixTest.Playwright.Case, unquote([{:async, false} | opts])

      use TrackerWeb, :verified_routes

      import Tracker.Fixtures

      @moduletag :playwright
    end
  end
end
