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
    test "navigates to the URL carrying the lens param", %{conn: conn, unstable: unstable} do
      {:ok, view, _html} = live(conn, ~p"/packages")

      assert {:error, {:live_redirect, %{to: to}}} = switch_to(view, unstable.name)
      assert to == ~p"/packages?channel=#{unstable.name}"
    end

    test "keeps the rest of the query string", %{conn: conn, unstable: unstable} do
      {:ok, view, _html} = live(conn, ~p"/packages?search=hello&page=2")

      assert {:error, {:live_redirect, %{to: to}}} = switch_to(view, unstable.name)
      params = to |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["search"] == "hello"
      assert params["page"] == "2"
      assert params["channel"] == unstable.name
    end

    test "replaces a previously pinned revision", %{conn: conn, unstable: unstable} do
      {:ok, view, _html} = live(conn, ~p"/packages?channel=nixos-old&rev=deadbeef")

      assert {:error, {:live_redirect, %{to: to}}} = switch_to(view, unstable.name)
      params = to |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["channel"] == unstable.name
      refute Map.has_key?(params, "rev")
    end

    test "persists the rendered lens to the cookie", %{conn: conn, unstable: unstable} do
      {:ok, view, _html} = live(conn, ~p"/packages")

      {:ok, _view, html} = switch_lens(conn, view, unstable.name)

      assert [token] =
               html |> Floki.parse_document!() |> Floki.attribute("#lens", "data-lens")

      assert {:ok, unstable.name} == TrackerWeb.Lens.verify_cookie(token)
    end
  end

  describe "the lens across navigation" do
    test "a navigation that drops the channel param has it patched back in", %{
      conn: conn,
      stable: stable
    } do
      {:ok, view, _html} = live(conn, ~p"/packages?channel=#{stable.name}")

      render_patch(view, ~p"/packages")

      assert_patch(view, ~p"/packages?channel=#{stable.name}")
    end

    test "an unknown channel canonicalizes to the one that actually rendered", %{
      conn: conn,
      stable: stable
    } do
      {:ok, view, _html} = live(conn, ~p"/packages?channel=#{stable.name}")

      render_patch(view, ~p"/packages?channel=nixos-nope")

      assert_patch(view, ~p"/packages?channel=#{stable.name}")
    end

    test "the client preference seeds a page that states no channel", %{
      conn: conn,
      unstable: unstable
    } do
      {:ok, view, html} =
        conn
        |> put_connect_params(%{"_lens" => sign_lens(unstable.name)})
        |> live(~p"/packages")

      assert selected_channel(html) == unstable.name

      render_patch(view, ~p"/packages")

      assert_patch(view, ~p"/packages?channel=#{unstable.name}")
    end

    test "nav links carry the switched channel", %{
      conn: conn,
      stable: stable,
      unstable: unstable
    } do
      {:ok, view, _html} = live(conn, ~p"/packages?channel=#{stable.name}")

      {:ok, _view, html} = switch_lens(conn, view, unstable.name)

      for href <- nav_hrefs(html) do
        assert URI.decode_query(URI.parse(href).query || "")["channel"] == unstable.name,
               "#{href} dropped the lens"
      end
    end

    test "following a nav link keeps the lens and shows it in the URL", %{
      conn: conn,
      stable: stable,
      unstable: unstable
    } do
      {:ok, view, _html} = live(conn, ~p"/packages?channel=#{stable.name}")

      {:ok, view, _html} = switch_lens(conn, view, unstable.name)

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element(".app-nav a[href^='/changes']") |> render_click()

      assert URI.decode_query(URI.parse(to).query)["channel"] == unstable.name

      {:ok, _next, html} = follow_redirect({:error, {:live_redirect, %{to: to}}}, conn)

      assert selected_channel(html) == unstable.name
    end
  end

  defp switch_to(view, channel_name) do
    view
    |> form("#lens-form", %{"channel" => channel_name})
    |> render_change()
  end

  defp sign_lens(channel_name) do
    Phoenix.Token.sign(TrackerWeb.Endpoint, TrackerWeb.Lens.cookie_salt(), channel_name)
  end

  defp selected_channel(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#lens-channel option[selected]")
    |> Floki.text()
    |> String.trim()
  end

  defp nav_hrefs(html) do
    html
    |> Floki.parse_document!()
    |> Floki.attribute(".app-nav a", "href")
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
