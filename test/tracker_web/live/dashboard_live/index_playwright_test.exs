defmodule TrackerWeb.DashboardLive.IndexPlaywrightTest do
  use TrackerWeb.PlaywrightCase

  alias Tracker.Nixpkgs.{ChannelRevision, RevisionSummary}
  alias Tracker.Notifications.ChangeSubscription

  setup do
    path = Path.join(System.tmp_dir!(), "dev-login-#{System.unique_integer([:positive])}.json")
    Application.put_env(:tracker, :dev_login_file, path)
    on_exit(fn -> File.rm(path) end)

    user = register_user!()
    long_name = "dashboard-" <> String.duplicate("long-identifier-", 12)
    package = package!(long_name)

    for {name, offset} <- [{"nixos-26.05", 0}, {"nixos-unstable-small", 1}, {"nixos-unstable", 2}] do
      channel = channel!(name)

      previous =
        channel_revision!(channel, %{
          released_at: DateTime.add(~U[2026-09-01 00:00:00Z], offset, :hour)
        })

      current =
        channel_revision!(channel, %{
          released_at: DateTime.add(~U[2026-09-02 00:00:00Z], offset, :hour),
          previous_channel_revision_id: previous.id
        })

      apply_package_revision!(previous, [{package, "1"}], complete?: true)
      apply_package_revision!(current, [{package, "2"}], complete?: true)

      for revision <- [previous, current] do
        ChannelRevision.record_result!(revision, %{result: :success})
        ChannelRevision.record_options_result!(revision, %{options_result: :success})
      end

      current = ChannelRevision.get_by_id!(current.id)
      assert {:ok, _current} = RevisionSummary.persist(current)

      notification!(user, %{channel_id: channel.id, channel_revision_id: current.id})
    end

    changes =
      for i <- 1..9 do
        change!(nil, %{
          title: "browser-recent-#{i} " <> long_name,
          state: if(i == 9, do: :open, else: :merged),
          gh_updated_at: DateTime.add(~U[2026-09-03 00:00:00Z], i, :minute)
        })
      end

    ChangeSubscription.subscribe!(List.last(changes).id, nil, actor: user)
    %{user: user, long_name: long_name, changes: changes}
  end

  for width <- [1440, 390], signed_in? <- [false, true], lens <- ["nixos-26.05", "all"] do
    @width width
    @signed_in? signed_in?
    @lens lens
    @tag browser_context_opts: [viewport: %{width: width, height: 1000}]
    test "#{width}px #{if signed_in?, do: "signed in", else: "signed out"} #{lens} dashboard stays usable",
         %{conn: conn, user: user, long_name: long_name, changes: changes} do
      conn =
        if @signed_in? do
          visit(conn, "/dev/login/#{Tracker.DevLogin.issue!(user.github_username)}")
        else
          conn
        end

      conn = conn |> visit("/?channel=#{@lens}") |> assert_has("#dashboard", text: "Welcome")

      if @signed_in? do
        assert_has(conn, "[data-phx-main].phx-connected")
      else
        assert_has(conn, "[data-phx-main]:not(.phx-connected)")

        assert read(
                 conn,
                 "Array.from(document.scripts).some(script => new URL(script.src, location.href).pathname === '/assets/ui.js')"
               )

        refute read(
                 conn,
                 "Array.from(document.scripts).some(script => new URL(script.src, location.href).pathname === '/assets/app.js')"
               )

        assert read(conn, "typeof window.liveSocket === 'undefined'")
      end

      assert read(conn, "window.innerWidth") == @width
      assert read(conn, "document.documentElement.scrollWidth <= window.innerWidth")
      assert read(conn, "document.body.scrollWidth <= window.innerWidth")

      refute read(
               conn,
               "document.querySelector('#dashboard').innerText.includes('Before you upgrade')"
             )

      refute read(
               conn,
               "document.querySelector('#dashboard').innerText.includes('Pick up where you left off')"
             )

      refute read(conn, "document.querySelector('#dashboard').innerText.includes('Last checked')")

      refute read(
               conn,
               "document.querySelector('#dashboard').innerText.includes('Design preview')"
             )

      if @signed_in? do
        assert_has(conn, "#dashboard-inbox")

        assert_has(conn, "#dashboard-followed-changes .row-num",
          text: "##{List.last(changes).number}"
        )

        assert read(conn, "document.querySelectorAll('#dashboard-recent-changes').length") == 0
      else
        assert read(
                 conn,
                 "document.querySelectorAll('#dashboard-inbox, #dashboard-followed-changes').length"
               ) == 0

        if @lens == "all" do
          assert_has(conn, "#dashboard-recent-changes .pill-open")

          assert read(
                   conn,
                   "document.querySelectorAll('#dashboard-recent-changes .row-num').length"
                 ) == 7

          assert read(
                   conn,
                   "document.querySelector('#dashboard-recent-changes .row-num').textContent.trim()"
                 ) == "##{List.last(changes).number}"

          refute read(
                   conn,
                   "document.querySelector('#dashboard').innerText.toLowerCase().includes('sign in')"
                 )
        end
      end

      if @lens == "all" do
        assert read(
                 conn,
                 "document.querySelectorAll('#dashboard-package-changes, #dashboard-option-changes').length"
               ) == 0
      else
        assert_has(conn, "#dashboard-package-changes", text: long_name)
      end

      if @width == 390 do
        if @signed_in? do
          assert read(
                   conn,
                   "document.querySelector('#dashboard-inbox').getBoundingClientRect().top >= document.querySelector('#dashboard-revision-summary').getBoundingClientRect().bottom"
                 )
        else
          if @lens == "all" do
            assert read(
                     conn,
                     "document.querySelector('#dashboard-recent-changes').getBoundingClientRect().top >= document.querySelector('#dashboard-revision-summary').getBoundingClientRect().bottom"
                   )
          end
        end
      end

      conn = evaluate(conn, "document.querySelector('#dashboard a[href]').focus()")
      press(conn, "body", "Tab")
      assert read(conn, "document.activeElement.matches('a, button, input, select')")
      assert read(conn, "document.activeElement.matches(':focus-visible')")

      assert read(
               conn,
               "getComputedStyle(document.activeElement).outlineStyle !== 'none' || getComputedStyle(document.activeElement).boxShadow !== 'none'"
             )
    end
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
end
