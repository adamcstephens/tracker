defmodule TrackerWeb.LensComponentTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tracker.Nixpkgs.Channel

  setup do
    suffix = System.unique_integer([:positive])

    stable =
      Channel.create!(%{
        name: "nixos-25.#{suffix}",
        display_name: "NixOS 25.#{suffix}",
        status: :active,
        is_stable: true
      })

    unstable =
      Channel.create!(%{
        name: "nixos-unstable-#{suffix}",
        display_name: "NixOS Unstable #{suffix}",
        status: :active,
        is_stable: false
      })

    %{stable: stable, unstable: unstable}
  end

  test "renders channel selector with active channels", %{
    conn: conn,
    stable: stable,
    unstable: unstable
  } do
    {:ok, _view, html} = live(conn, ~p"/packages")

    assert html =~ stable.name
    assert html =~ unstable.name
    assert html =~ ~s(id="lens")
  end

  test "the channel select carries the id the \"#\" shortcut focuses", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages")

    assert [_] =
             html
             |> Floki.parse_document!()
             |> Floki.find("select#lens-channel.lens__select")
  end

  test "current lens channel is selected", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages")

    # Default stable should be selected
    assert html =~ ~s(selected)
  end

  test "renders divided pill with Channel label", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages")

    assert html =~ ~s(class="lens-label")
    assert html =~ "Channel"
  end

  test "does not render a Rev toggle button or rev input", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages")

    refute html =~ ~s(>Rev</button)
    refute html =~ ~s(name="rev")
  end

  test "renders 'All channels' option in dropdown", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages")

    assert html =~ ~s(value="all")
    assert html =~ "All channels"
  end

  test "renders a submit button so the lens works without JS", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages")

    [form] =
      html
      |> Floki.parse_document!()
      |> Floki.find("form.lens__form")

    assert Floki.find(form, "button[type=submit]") != []
  end

  test "channel pages grey out the lens and search", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/channels")

    assert html =~ "lens--disabled"
    assert html =~ "app-search--inert"
  end

  test "regular pages do not grey out the lens", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/packages")

    refute html =~ "lens--disabled"
    refute html =~ "app-search--inert"
  end

  describe "switching the channel" do
    test "patches the URL with the lens param", %{conn: conn, unstable: unstable} do
      {:ok, view, _html} = live(conn, ~p"/packages")

      view
      |> form("#lens-form", %{"channel" => unstable.name})
      |> render_change()

      assert_patch(view, ~p"/packages?channel=#{unstable.name}")
    end

    test "keeps the rest of the query string", %{conn: conn, unstable: unstable} do
      {:ok, view, _html} = live(conn, ~p"/packages?search=hello&page=2")

      view
      |> form("#lens-form", %{"channel" => unstable.name})
      |> render_change()

      path = assert_patch(view)
      assert %{query: query} = URI.parse(path)
      params = URI.decode_query(query)

      assert params["search"] == "hello"
      assert params["page"] == "2"
      assert params["channel"] == unstable.name
    end

    test "replaces a previously pinned revision", %{conn: conn, unstable: unstable} do
      {:ok, view, _html} = live(conn, ~p"/packages?channel=nixos-old&rev=deadbeef")

      view
      |> form("#lens-form", %{"channel" => unstable.name})
      |> render_change()

      path = assert_patch(view)
      params = path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["channel"] == unstable.name
      refute Map.has_key?(params, "rev")
    end

    test "persists the choice to the cookie", %{conn: conn, unstable: unstable} do
      {:ok, view, _html} = live(conn, ~p"/packages")

      view
      |> form("#lens-form", %{"channel" => unstable.name})
      |> render_change()

      assert_push_event(view, "set_lens_cookie", payload)
      assert {:ok, unstable.name} == TrackerWeb.Lens.verify_cookie(payload.value)
    end
  end

  test "renders the channel's latest revision when none is pinned", %{conn: conn} do
    suffix = System.unique_integer([:positive])

    channel =
      Channel.create!(%{
        name: "nixos-latest-#{suffix}",
        display_name: "NixOS Latest #{suffix}",
        status: :active,
        is_stable: false
      })

    cr =
      Tracker.Nixpkgs.ChannelRevision
      |> Ash.Changeset.for_create(:create, %{
        channel_id: channel.id,
        revision: "fedcba9876543210",
        released_at: ~U[2025-06-01 00:00:00Z]
      })
      |> Ash.create!()

    Tracker.Nixpkgs.ChannelRevision.record_options_result!(cr, %{options_result: :success})

    token =
      Phoenix.Token.sign(
        TrackerWeb.Endpoint,
        TrackerWeb.Lens.cookie_salt(),
        channel.name
      )

    conn = put_req_cookie(conn, "_tracker_lens", token)

    {:ok, _view, html} = live(conn, ~p"/packages")

    assert html =~ ~s(class="lens-rev")
    assert html =~ "@fedcba9"
  end

  test "renders short revision when lens has a revision set", %{conn: conn} do
    suffix = System.unique_integer([:positive])

    channel =
      Channel.create!(%{
        name: "nixos-rev-#{suffix}",
        display_name: "NixOS Rev #{suffix}",
        status: :active,
        is_stable: false
      })

    rev_hash = "abcdef1234567890"

    Tracker.Nixpkgs.ChannelRevision
    |> Ash.Changeset.for_create(:create, %{
      channel_id: channel.id,
      revision: rev_hash,
      released_at: ~U[2025-06-01 00:00:00Z]
    })
    |> Ash.create!()

    token =
      Phoenix.Token.sign(
        TrackerWeb.Endpoint,
        TrackerWeb.Lens.cookie_salt(),
        "#{channel.name}:#{rev_hash}"
      )

    conn = put_req_cookie(conn, "_tracker_lens", token)

    {:ok, _view, html} = live(conn, ~p"/packages")

    assert html =~ ~s(class="lens-rev")
    assert html =~ "@abcdef1"
  end
end
