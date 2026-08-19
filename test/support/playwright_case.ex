defmodule TrackerWeb.PlaywrightCase do
  @moduledoc """
  Case template for tests that need a real browser.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use PhoenixTest.Playwright.Case, async: false

      use TrackerWeb, :verified_routes

      import Tracker.Fixtures

      @moduletag :playwright
    end
  end
end
