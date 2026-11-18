defmodule TrackerWeb.Browser.ChannelSelectionTest do
  use TrackerWeb.PlaywrightCase
  @moduletag browser_launch_timeout: 30_000

  test "anonymous selection limits, clears and submits chronological endpoints", %{conn: conn} do
    channel = channel!("browser-selection")

    revisions =
      for n <- 1..3 do
        channel_revision!(channel, %{
          revision: String.duplicate(to_string(n), 40),
          released_at: DateTime.add(~U[2026-03-01 10:00:00Z], n, :day)
        })
      end

    [older, newer, latest] = revisions
    conn = visit(conn, "/channels/#{channel.name}")
    assert_has(conn, "#compare-selected[disabled]")
    assert_has(conn, "#comparison-guidance", text: "Select two revisions to compare.")
    refute_has(conn, "#clear-selection")
    evaluate(conn, "document.querySelector('#select-#{newer.id}').click()")
    assert_has(conn, "#compare-selected[disabled]")
    assert_has(conn, "#comparison-guidance", text: "Select one more revision to compare.")
    evaluate(conn, "document.querySelector('#select-#{older.id}').click()")
    assert_has(conn, "#compare-selected:not([disabled])")
    assert_has(conn, "#comparison-from", text: String.slice(older.revision, 0, 7))
    assert_has(conn, "#comparison-to", text: String.slice(newer.revision, 0, 7))
    assert_has(conn, "#comparison-guidance", text: "2 revisions selected")
    assert_has(conn, "#select-#{latest.id}[disabled]")
    click(conn, "#clear-selection")
    assert_has(conn, "#compare-selected[disabled]")
    assert_has(conn, "#select-#{latest.id}:not([disabled])")

    evaluate(
      conn,
      "document.querySelector('#select-#{newer.id}').click(); document.querySelector('#select-#{older.id}').click()"
    )

    evaluate(
      conn,
      "if (new FormData(document.querySelector('#revisions-form')).getAll('compare[]').join(',') !== '#{older.revision},#{newer.revision}') throw new Error('wrong chronological submission')"
    )

    click(conn, "#compare-selected")
    assert_path(conn, "/channels/#{channel.name}/diff/#{older.revision}/#{newer.revision}")
  end

  test "signed-in pagination reconciles selection and permits reselection", %{conn: conn} do
    path = Path.join(System.tmp_dir!(), "dev-login-#{System.unique_integer([:positive])}.json")
    Application.put_env(:tracker, :dev_login_file, path)
    on_exit(fn -> File.rm(path) end)
    user = register_user!()
    channel = channel!("browser-selection-live")

    revisions =
      for n <- 1..22 do
        channel_revision!(channel, %{
          revision: String.pad_leading(to_string(n), 40, "0"),
          released_at: DateTime.add(~U[2026-03-01 10:00:00Z], n, :day)
        })
      end

    older = Enum.at(revisions, 0)
    newer = Enum.at(revisions, 1)
    latest = List.last(revisions)

    conn =
      conn
      |> visit("/dev/login/#{Tracker.DevLogin.issue!(user.github_username)}")
      |> visit("/channels/#{channel.name}")

    assert_has(conn, "[data-phx-main].phx-connected")
    evaluate(conn, "document.querySelector('#select-#{latest.id}').click()")
    assert_has(conn, "#comparison-guidance", text: "Select one more revision to compare.")
    click(conn, "a[href*='page=2']")
    assert_has(conn, "#select-#{older.id}")
    assert_has(conn, "#compare-selected[disabled]")
    refute_has(conn, "#clear-selection")
    assert_has(conn, "#comparison-guidance", text: "Select two revisions to compare.")

    evaluate(
      conn,
      "document.querySelector('#select-#{newer.id}').click(); document.querySelector('#select-#{older.id}').click()"
    )

    assert_has(conn, "#compare-selected:not([disabled])")

    evaluate(
      conn,
      "if (new FormData(document.querySelector('#revisions-form')).getAll('compare[]').join(',') !== '#{older.revision},#{newer.revision}') throw new Error('wrong chronological submission after patch')"
    )
  end
end
