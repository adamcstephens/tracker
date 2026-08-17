defmodule TrackerWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use TrackerWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint TrackerWeb.Endpoint

      use TrackerWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import TrackerWeb.ConnCase
    end
  end

  setup tags do
    Tracker.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Switches the sitewide lens the way a visitor does, through the nav selector.

  The switch navigates rather than patches, so this follows the redirect and
  returns `{:ok, view, html}` for the re-mounted page. A macro because
  `follow_redirect/2` needs the caller's `@endpoint`.
  """
  defmacro switch_lens(conn, view, channel_name) do
    quote do
      unquote(view)
      |> Phoenix.LiveViewTest.form("#lens-form", %{"channel" => unquote(channel_name)})
      |> Phoenix.LiveViewTest.render_change()
      |> Phoenix.LiveViewTest.follow_redirect(unquote(conn))
    end
  end

  @doc """
  Asserts the next patch went to `expected`, disregarding the sitewide lens.

  Every internal URL carries the lens (see `TrackerWeb.Lens`), which is noise in
  a test about some other param.
  """
  def assert_patch_ignoring_lens(view, expected) do
    assert_same_path(Phoenix.LiveViewTest.assert_patch(view), expected)
  end

  @doc """
  Asserts two paths match once the sitewide lens is stripped from both.
  """
  def assert_same_path(actual, expected) do
    ExUnit.Assertions.assert(without_lens(actual) == without_lens(expected))
  end

  defp without_lens(path) do
    uri = URI.parse(path)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.drop(["channel", "rev"])
      |> URI.encode_query()

    URI.to_string(%{uri | query: if(query == "", do: nil, else: query)})
  end
end
