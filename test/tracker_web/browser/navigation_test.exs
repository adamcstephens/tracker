defmodule TrackerWeb.Browser.NavigationTest do
  use TrackerWeb.PlaywrightCase

  @jumps [{"p", "/packages"}, {"o", "/options"}, {"c", "/changes"}, {"n", "/inbox"}]

  @arm """
  window.__opened = null
  window.open = (...args) => { window.__opened = args }
  """

  @second_row "ul.row-list > li:nth-child(2)"

  setup do
    path = Path.join(System.tmp_dir!(), "dev-login-#{System.unique_integer([:positive])}.json")
    Application.put_env(:tracker, :dev_login_file, path)
    on_exit(fn -> File.rm(path) end)

    channel!()
    for number <- 9001..9003, do: change!(number)

    :ok
  end

  defp read(conn, expression) do
    parent = self()
    evaluate(conn, expression, &send(parent, {:read, &1}))

    receive do
      {:read, value} -> value
    after
      0 -> flunk("evaluate/3 returned no value for #{expression}")
    end
  end

  defp changes_page(conn), do: conn |> visit(~p"/changes") |> evaluate(@arm)

  defp sign_in(conn) do
    user = register_user!()
    visit(conn, "/dev/login/#{Tracker.DevLogin.issue!(user.github_username)}")
  end

  defp cursor_moved?(conn), do: read(conn, ~s|document.activeElement.matches(".row-line")|)

  for {key, destination} <- @jumps do
    @key key
    @destination destination

    test "g then #{key} jumps to #{destination}", %{conn: conn} do
      conn = conn |> sign_in() |> visit(~p"/changes")

      press(conn, "body", "g")
      press(conn, "body", @key)

      assert_path(conn, @destination)
    end
  end

  test "a jump carries the search query the nav links carry", %{conn: conn} do
    conn = conn |> sign_in() |> visit(~p"/changes?search=hello")

    press(conn, "body", "g")
    press(conn, "body", "p")

    assert_path(conn, "/packages")
    assert read(conn, ~s|new URLSearchParams(location.search).get("search")|) == "hello"
  end

  test "reconnecting with a disabled lens keeps the channels page usable", %{conn: conn} do
    conn = conn |> sign_in() |> visit(~p"/channels")
    assert_has(conn, "[data-phx-main].phx-connected")
    assert_has(conn, "#lens-channel[disabled]")

    evaluate(
      conn,
      """
      new Promise((resolve, reject) => {
        window.liveSocket.disconnect(() => {
          const root = document.querySelector("[data-phx-main]")
          const observer = new MutationObserver(() => {
            if (root.classList.contains("phx-connected")) {
              observer.disconnect()
              window.removeEventListener("phx:page-loading-start", onError)
              resolve(true)
            }
          })
          const onError = event => {
            if (event.detail.errorKind === "server") {
              observer.disconnect()
              window.removeEventListener("phx:page-loading-start", onError)
              reject(new Error("LiveView crashed during reconnect"))
            }
          }
          observer.observe(root, {attributes: true, attributeFilter: ["class"]})
          window.addEventListener("phx:page-loading-start", onError)
          window.liveSocket.connect()
        })
      })
      """,
      fn connected? -> assert connected? end
    )

    assert_path(conn, "/channels")
    click_link(conn, ".app-nav a[href^='/packages']", "Packages")
    assert_path(conn, "/packages")
    assert_has(conn, "#lens-channel:not([disabled])")
  end

  test "g then an unmapped key is swallowed and moves nothing", %{conn: conn} do
    conn = changes_page(conn)

    press(conn, "body", "g")
    press(conn, "body", "k")

    refute cursor_moved?(conn)
    assert_path(conn, "/changes")
  end

  test "the chord expires and hands the next key back to the cursor", %{conn: conn} do
    conn = changes_page(conn)

    press(conn, "body", "g")
    Process.sleep(1_100)
    press(conn, "body", "k")

    assert cursor_moved?(conn)
  end

  test "? opens the shortcuts dialog and ? closes it again", %{conn: conn} do
    conn = changes_page(conn)

    press(conn, "body", "?")
    assert read(conn, ~s|document.getElementById("shortcuts").open|)

    press(conn, "#shortcuts .shortcuts__close", "?")
    refute read(conn, ~s|document.getElementById("shortcuts").open|)
  end

  test "the open dialog makes the page behind it inert", %{conn: conn} do
    conn = changes_page(conn)

    press(conn, "body", "?")
    evaluate(conn, ~s|document.querySelector("ul.row-list > li > .row-line").focus()|)

    refute cursor_moved?(conn)
  end

  test "clicking the backdrop closes the dialog but clicking the card does not", %{conn: conn} do
    conn = changes_page(conn)

    press(conn, "body", "?")
    click_at(conn, "#shortcuts .card", 5, 5)
    assert read(conn, ~s|document.getElementById("shortcuts").open|)

    click_at(conn, "#shortcuts", 5, 5)
    refute read(conn, ~s|document.getElementById("shortcuts").open|)
  end

  test "v prefers the focused row's link over the page's", %{conn: conn} do
    conn = changes_page(conn)

    page_link = read(conn, ~s|document.querySelector("a[data-external-link]").href|)
    row_link = read(conn, ~s|document.querySelector("#{@second_row} a[data-external-link]").href|)
    assert row_link != page_link

    press(conn, "#{@second_row} > .row-line", "v")
    assert read(conn, "window.__opened[0]") == row_link
  end

  test "v falls back to the page's link with no row focused", %{conn: conn} do
    conn = changes_page(conn)

    page_link = read(conn, ~s|document.querySelector("a[data-external-link]").href|)

    press(conn, "body", "v")
    assert read(conn, "window.__opened[0]") == page_link
  end

  test "v is inert on a page carrying no external link", %{conn: conn} do
    conn = conn |> visit(~p"/packages") |> evaluate(@arm)
    assert read(conn, ~s|document.querySelectorAll("a[data-external-link]").length|) == 0

    press(conn, "body", "v")
    assert read(conn, "window.__opened") == nil
  end

  defp click_at(conn, selector, x, y) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      PlaywrightEx.Frame.click(frame_id,
        selector: selector,
        position: %{x: x, y: y},
        timeout: timeout()
      )
    end)
  end
end
