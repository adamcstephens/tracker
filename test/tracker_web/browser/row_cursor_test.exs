defmodule TrackerWeb.Browser.RowCursorTest do
  use TrackerWeb.PlaywrightCase

  alias Tracker.Nixpkgs.Channel
  alias Tracker.Nixpkgs.ChannelRevision

  @options %{
    "services.nginx.enable" => %{
      "declarations" => ["nixos/modules/nginx.nix"],
      "description" => "Enable Nginx.",
      "loc" => ["services", "nginx", "enable"],
      "readOnly" => false,
      "type" => "boolean"
    },
    "services.nginx.group" => %{
      "declarations" => ["nixos/modules/nginx.nix"],
      "description" => "Group to run Nginx as.",
      "loc" => ["services", "nginx", "group"],
      "readOnly" => false,
      "type" => "string"
    },
    "services.nginx.user" => %{
      "declarations" => ["nixos/modules/nginx.nix"],
      "description" => "User to run Nginx as.",
      "loc" => ["services", "nginx", "user"],
      "readOnly" => false,
      "type" => "string"
    },
    "services.nginx.upstreams.example.servers" => %{
      "declarations" => ["nixos/modules/upstream.nix"],
      "description" => "Upstream servers.",
      "loc" => ["services", "nginx", "upstreams", "example", "servers"],
      "readOnly" => false,
      "type" => "attribute set"
    },
    "services.nginx.virtualHosts.example.serverName" => %{
      "declarations" => ["nixos/modules/vhost.nix"],
      "description" => "Server name for the vhost.",
      "loc" => ["services", "nginx", "virtualHosts", "example", "serverName"],
      "readOnly" => false,
      "type" => "string"
    }
  }

  @rows ~s|document.querySelectorAll("ul.row-list > li > .row-line, ul.row-list > li > details > summary")|
  @cursor "[...#{@rows}].indexOf(document.activeElement)"

  @second_leaf "#options-list > li:nth-child(2) > details > summary"

  setup do
    channel =
      Channel.create!(%{
        name: "nixos-rowcursor",
        display_name: "NixOS",
        status: :active,
        is_stable: true
      })

    revision =
      ChannelRevision.create!(%{
        channel_id: channel.id,
        revision: "rowcursor12345",
        released_at: ~U[2026-03-15 10:00:00Z]
      })

    ChannelRevision.record_result!(revision, %{result: :success})
    revision = ChannelRevision.record_options_result!(revision, %{options_result: :success})
    load_options(@options, revision)

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

  defp options_page(conn), do: visit(conn, ~p"/options/services.nginx")

  defp blur(conn), do: evaluate(conn, "document.activeElement.blur()")

  defp walk(conn, key, times) do
    Enum.map(1..times, fn _ ->
      press(conn, "body", key)
      read(conn, @cursor)
    end)
  end

  defp cursor(conn), do: read(conn, @cursor)
  defp cursor_list(conn), do: read(conn, ~s|document.activeElement.closest("ul.row-list").id|)

  test "j and k walk every row on the page in document order", %{conn: conn} do
    conn = options_page(conn)
    last = read(conn, "#{@rows}.length") - 1

    assert walk(blur(conn), "j", last + 1) == Enum.to_list(0..last)
    assert walk(conn, "k", last) == Enum.to_list((last - 1)..0)
  end

  test "the cursor stops at both ends rather than wrapping", %{conn: conn} do
    conn = options_page(conn)
    last = read(conn, "#{@rows}.length") - 1

    walk(blur(conn), "j", last + 1)
    assert walk(conn, "j", 2) == [last, last]

    walk(conn, "k", last)
    assert walk(conn, "k", 2) == [0, 0]
  end

  test "with nothing focused j takes the first row and k does nothing", %{conn: conn} do
    conn = options_page(conn)

    press(blur(conn), "body", "k")
    assert cursor(conn) == -1

    press(conn, "body", "j")
    assert cursor(conn) == 0
  end

  test "the cursor picks up from the row the mouse left it on", %{conn: conn} do
    conn = options_page(conn)

    click(conn, @second_leaf)
    clicked = cursor(conn)
    assert clicked > 0

    assert walk(conn, "j", 1) == [clicked + 1]
  end

  test "mouse and keyboard hand off a single highlighted row", %{conn: conn} do
    conn = options_page(conn)

    {:ok, _} = PlaywrightEx.Frame.hover(conn.frame_id, selector: @second_leaf, timeout: 2000)
    assert_highlighted_rows(conn, [1])

    press(conn, "body", "j")
    assert cursor(conn) == 2
    assert_highlighted_rows(conn, [2])

    {:ok, _} =
      PlaywrightEx.Frame.hover(conn.frame_id,
        selector: "#options-list > li:nth-child(4) > details > summary",
        timeout: 2000
      )

    assert_highlighted_rows(conn, [3])

    press(conn, "body", "k")
    assert cursor(conn) == 2
    assert_highlighted_rows(conn, [2])
  end

  defp assert_highlighted_rows(conn, expected) do
    assert {:ok, _} =
             PlaywrightEx.Frame.wait_for_function(conn.frame_id,
               timeout: 2000,
               expression: """
               (() => {
                 const highlighted = [...#{@rows}].flatMap((row, index) => {
                   const style = getComputedStyle(row)
                   return style.backgroundColor !== "rgba(0, 0, 0, 0)" || style.outlineStyle !== "none"
                     ? [index] : []
                 })
                 return JSON.stringify(highlighted) === #{inspect(Jason.encode!(expected))}
               })()
               """
             )
  end

  test "the page's several lists are one cursor", %{conn: conn} do
    conn = options_page(conn)

    evaluate(conn, """
    document.querySelector(".option-show").insertAdjacentHTML("beforeend", `
      <ul class="row-list" id="additional-list">
        <li><div class="row-line" tabindex="-1">additional row</div></li>
      </ul>`)
    """)

    press(blur(conn), "body", "j")
    assert cursor_list(conn) == "options-list"

    walk(
      conn,
      "j",
      read(conn, ~s|document.querySelectorAll("#options-list > li").length|)
    )

    assert cursor_list(conn) == "additional-list"
    assert cursor(conn) > 0
  end

  test "a list nested in an expanded row falls in at that row", %{conn: conn} do
    conn = options_page(conn)

    evaluate(conn, """
    let details = document.querySelector("#options-list > li > details")
    details.open = true
    details.insertAdjacentHTML("beforeend", `
      <ul class="row-list" id="nested">
        <li><div class="row-line" tabindex="-1">nested row</div></li>
      </ul>`)
    """)

    parent = read(conn, ~s|[...#{@rows}].findIndex((e) => e.tagName === "SUMMARY")|)

    walk(blur(conn), "j", parent + 1)
    assert cursor_list(conn) == "options-list"

    assert walk(conn, "j", 1) == [parent + 1]
    assert cursor_list(conn) == "nested"
  end
end
