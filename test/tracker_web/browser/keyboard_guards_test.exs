defmodule TrackerWeb.Browser.KeyboardGuardsTest do
  use TrackerWeb.PlaywrightCase

  @probes """
  window.__consumed = null
  window.__opened = null
  window.__toggles = 0

  if (!window.__probed) {
    window.__probed = true
    document.addEventListener("keydown", (e) => { window.__consumed = e.defaultPrevented })
    window.open = (...args) => { window.__opened = args }
    document.body.insertAdjacentHTML("beforeend", `
      <div id="probes">
        <input id="probe-input">
        <textarea id="probe-textarea"></textarea>
        <div id="probe-ce" contenteditable="true">x</div>
        <select id="probe-select"><option>a</option><option>b</option></select>
      </div>`)
  }

  document.querySelectorAll("button[phx-click='toggle-read']").forEach((button) => {
    if (button.dataset.counted) return
    button.dataset.counted = "1"
    button.addEventListener("click", (e) => {
      window.__toggles++
      e.stopPropagation()
      e.preventDefault()
    }, true)
  })
  """

  @reset """
  document.activeElement.blur()
  let dialog = document.getElementById("shortcuts")
  if (dialog.open) dialog.close()
  window.__consumed = null
  window.__opened = null
  window.__toggles = 0
  """

  @row "ul.row-list > li:nth-child(2) > .row-line"
  @close "#shortcuts .shortcuts__close"

  @guard_defaults %{focus: :from, modifier: "", open_dialog?: false}

  @guards [
    %{context: :input, focus: "#probe-input"},
    %{context: :textarea, focus: "#probe-textarea"},
    %{context: :contenteditable, focus: "#probe-ce"},
    %{context: :select, focus: "#probe-select"},
    %{context: :dialog, focus: @close, open_dialog?: true},
    %{context: :ctrl, modifier: "Control+"},
    %{context: :meta, modifier: "Meta+"},
    %{context: :alt, modifier: "Alt+"},
    %{context: :shift, modifier: "Shift+"}
  ]

  @cursor_moved ~s|document.activeElement.matches(".row-line")|

  @on_changes [
    %{
      name: "/",
      key: "/",
      from: "body",
      survives: [:shift],
      fires: ~s|document.activeElement.id === "page-search-input"|
    },
    %{
      name: "#",
      key: "#",
      from: "body",
      survives: [:shift],
      fires: ~s|document.activeElement.id === "lens-channel"|
    },
    %{
      name: "?",
      key: "?",
      from: "body",
      survives: [:shift, :dialog],
      fires: ~s|document.getElementById("shortcuts").open|
    },
    %{name: "v", key: "v", from: "body", survives: [], fires: "!!window.__opened"},
    %{name: "j", key: "j", from: "body", survives: [:select], fires: @cursor_moved},
    %{name: "k", key: "k", from: "body", survives: [:select], fires: @cursor_moved},
    %{name: "ArrowDown", key: "ArrowDown", from: "body", survives: [], fires: @cursor_moved},
    %{name: "ArrowUp", key: "ArrowUp", from: "body", survives: [], fires: @cursor_moved}
  ]

  @on_inbox [%{name: "m", key: "m", from: @row, survives: [], fires: "window.__toggles > 0"}]

  setup do
    path = Path.join(System.tmp_dir!(), "dev-login-#{System.unique_integer([:positive])}.json")
    Application.put_env(:tracker, :dev_login_file, path)
    on_exit(fn -> File.rm(path) end)
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

  defp fire(conn, selector, key, open_dialog? \\ false) do
    conn = evaluate(conn, @reset)
    if open_dialog?, do: evaluate(conn, ~s|document.getElementById("shortcuts").showModal()|)
    press(conn, selector, key)
    conn
  end

  defp changes_page(conn) do
    channel!()
    for offset <- 1..3, do: change!(9000 + offset)

    conn |> visit(~p"/changes") |> evaluate(@probes)
  end

  defp inbox_page(conn) do
    channel!()
    user = register_user!()
    for _ <- 1..4, do: notification!(user)

    conn
    |> visit("/dev/login/#{Tracker.DevLogin.issue!(user.github_username)}")
    |> visit(~p"/inbox")
    |> evaluate(@probes)
  end

  defp assert_guards(conn, shortcut) do
    %{name: name, key: key, from: from, fires: fires, survives: survives} = shortcut
    conn = fire(conn, from, key)

    assert read(conn, fires) == true,
           ~s|"#{name}" did not fire with the page focused, so its guard cases prove nothing|

    for guard <- @guards do
      %{context: context, focus: focus, modifier: modifier, open_dialog?: open_dialog?} =
        Map.merge(@guard_defaults, guard)

      conn = fire(conn, if(focus == :from, do: from, else: focus), modifier <> key, open_dialog?)
      consumed = read(conn, "window.__consumed")

      if context in survives do
        assert consumed == true, ~s|"#{name}" should still act under #{context}|
      else
        assert consumed == false, ~s|"#{name}" should be inert under #{context}|
      end
    end
  end

  for shortcut <- @on_changes do
    @shortcut shortcut
    test "#{shortcut.name} honours its guards", %{conn: conn} do
      conn |> changes_page() |> assert_guards(@shortcut)
    end
  end

  for shortcut <- @on_inbox do
    @shortcut shortcut
    test "#{shortcut.name} honours its guards", %{conn: conn} do
      conn |> inbox_page() |> assert_guards(@shortcut)
    end
  end

  test "? closes the dialog it opened rather than being swallowed by it", %{conn: conn} do
    conn = changes_page(conn)

    conn = fire(conn, "body", "?")
    assert read(conn, ~s|document.getElementById("shortcuts").open|) == true

    press(conn, @close, "?")
    assert read(conn, ~s|document.getElementById("shortcuts").open|) == false
  end

  test "arrow keys yield to a focused select but j and k do not", %{conn: conn} do
    conn = changes_page(conn)

    for key <- ~w(ArrowDown ArrowUp) do
      conn = fire(conn, "#probe-select", key)

      assert read(conn, ~s|document.activeElement.id|) == "probe-select",
             "#{key} should leave a focused select alone"
    end

    for key <- ~w(j k) do
      conn = fire(conn, "#probe-select", key)

      assert read(conn, ~s|document.activeElement.matches(".row-line")|) == true,
             "#{key} should move the cursor even from a focused select"
    end
  end

  test "g honours its guards", %{conn: conn} do
    conn = changes_page(conn)

    assert chord_armed?(conn, "body", "g"), "g did not arm the chord with the page focused"

    for guard <- @guards do
      %{context: context, focus: focus, modifier: modifier, open_dialog?: open_dialog?} =
        Map.merge(@guard_defaults, guard)

      armed =
        chord_armed?(
          conn,
          if(focus == :from, do: "body", else: focus),
          modifier <> "g",
          open_dialog?
        )

      # g rides the row-navigation listener, so isTextEntry lets it through a select.
      if context == :select do
        assert armed, "g should still arm the chord under #{context}"
      else
        refute armed, "g should be inert under #{context}"
      end
    end
  end

  defp chord_armed?(conn, selector, key, open_dialog? \\ false) do
    conn = fire(conn, selector, key, open_dialog?)
    conn = evaluate(conn, @reset)
    press(conn, "body", "k")

    read(conn, ~s|document.activeElement.matches(".row-line")|) == false
  end
end
