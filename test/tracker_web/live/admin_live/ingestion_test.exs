defmodule TrackerWeb.AdminLive.IngestionTest do
  use TrackerWeb.ConnCase, async: true
  use Oban.Testing, repo: Tracker.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Tracker.Accounts.User
  alias Tracker.Ingestion.{IngestionRun, Pipeline, StepWorker}
  alias Tracker.Nixpkgs.Channel

  setup do
    channel =
      Channel.create!(%{
        name: "nixpkgs-adminingest",
        display_name: "Nixpkgs Unstable",
        status: :active,
        is_stable: false
      })

    {:ok, channel: channel}
  end

  describe "access" do
    test "redirects anonymous visitors to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin")
    end

    test "redirects non-admin users home", %{conn: conn} do
      user = register_via_github!()
      refute User.has_role?(user, :admin)

      assert {:error, {:redirect, %{to: "/"}}} = conn |> log_in(user) |> live(~p"/admin")
    end

    test "admins reach the page", %{conn: conn} do
      {:ok, _view, html} = conn |> log_in(admin!()) |> live(~p"/admin")

      assert html =~ "Ingestion"
    end

    test "ash admin is still reachable at its new path", %{conn: conn} do
      conn = conn |> log_in(admin!()) |> get(~p"/admin/ash")

      refute redirected_to_auth?(conn)
    end
  end

  describe "listing" do
    test "shows a failed pipeline with its channel, step and error", %{
      conn: conn,
      channel: channel
    } do
      pipeline =
        create_pipeline!(channel, %{revision: "d14ae62671fd4eaec57427da1e50f91d6a5f9605"})

      Pipeline.mark_failed!(pipeline, :finalize, "unknown registry: Hologram.PubSub")

      {:ok, _view, html} = conn |> log_in(admin!()) |> live(~p"/admin")

      assert html =~ "nixpkgs-adminingest"
      assert html =~ "d14ae62"
      assert html =~ "finalize"
      assert html =~ "unknown registry"
    end

    test "shows how many pipelines are blocked behind the head", %{conn: conn, channel: channel} do
      head = create_pipeline!(channel, %{revision: "head", sequence: 0})
      Pipeline.mark_failed!(head, :finalize, "boom")

      create_pipeline!(channel, %{revision: "blocked1", sequence: 1})
      create_pipeline!(channel, %{revision: "blocked2", sequence: 2})

      {:ok, view, _html} = conn |> log_in(admin!()) |> live(~p"/admin")

      assert has_element?(view, "[data-blocked-count]", "2")
    end

    test "links to the pipeline's oban jobs", %{conn: conn, channel: channel} do
      pipeline = create_pipeline!(channel)
      Pipeline.mark_failed!(pipeline, :finalize, "boom")

      {:ok, view, _html} = conn |> log_in(admin!()) |> live(~p"/admin")

      # `++` must reach Oban Web percent-encoded; as a bare `+` it decodes to a
      # space and the args filter is dropped without complaint.
      assert has_element?(
               view,
               ~s{a[href="/dev/oban/jobs?args=pipeline_id%2B%2B#{pipeline.id}&state=discarded"]}
             )
    end

    test "omits healthy pipelines", %{conn: conn, channel: channel} do
      create_pipeline!(channel, %{revision: "pending"})
      completed = create_pipeline!(channel, %{revision: "completed", sequence: 1})
      Pipeline.mark_completed!(completed)

      {:ok, _view, html} = conn |> log_in(admin!()) |> live(~p"/admin")

      refute html =~ "pending"
      assert html =~ "No unhealthy pipelines"
    end
  end

  describe "retry" do
    test "re-drives a failed pipeline from its failed step", %{conn: conn, channel: channel} do
      pipeline = create_pipeline!(channel)
      Pipeline.mark_failed!(pipeline, :finalize, "boom")

      {:ok, view, _html} = conn |> log_in(admin!()) |> live(~p"/admin")

      html = view |> element(~s{button[phx-value-id="#{pipeline.id}"]}) |> render_click()

      assert html =~ "Retrying"

      retried = Pipeline.get_pipeline!(pipeline.id)
      assert retried.status == :running
      assert retried.failed_step == nil
      assert retried.retry_count == 0

      assert_enqueued(worker: StepWorker, args: %{pipeline_id: pipeline.id, step: "finalize"})
    end

    test "re-drives a stuck pipeline and clears its retry budget", %{
      conn: conn,
      channel: channel
    } do
      pipeline = create_pipeline!(channel)
      Pipeline.mark_stuck!(pipeline, :load_packages, "wedged")

      {:ok, view, _html} = conn |> log_in(admin!()) |> live(~p"/admin")

      view |> element(~s{button[phx-value-id="#{pipeline.id}"]}) |> render_click()

      retried = Pipeline.get_pipeline!(pipeline.id)
      assert retried.status == :running
      assert retried.retry_count == 0

      assert_enqueued(
        worker: StepWorker,
        args: %{pipeline_id: pipeline.id, step: "load_packages"}
      )
    end

    test "drops the pipeline from the list once it is retried", %{conn: conn, channel: channel} do
      pipeline = create_pipeline!(channel, %{revision: "wedged-revision"})
      Pipeline.mark_failed!(pipeline, :finalize, "boom")

      {:ok, view, _html} = conn |> log_in(admin!()) |> live(~p"/admin")

      html = view |> element(~s{button[phx-value-id="#{pipeline.id}"]}) |> render_click()

      refute html =~ "wedged-revision"
    end

    test "reports when the pipeline changed state underneath the admin", %{
      conn: conn,
      channel: channel
    } do
      pipeline = create_pipeline!(channel)
      Pipeline.mark_failed!(pipeline, :finalize, "boom")

      {:ok, view, _html} = conn |> log_in(admin!()) |> live(~p"/admin")

      Pipeline.mark_completed!(Pipeline.get_pipeline!(pipeline.id))

      html = view |> element(~s{button[phx-value-id="#{pipeline.id}"]}) |> render_click()

      assert html =~ "could not be retried"
      refute_enqueued(worker: StepWorker, args: %{pipeline_id: pipeline.id})
    end
  end

  defp create_pipeline!(channel, attrs \\ %{}) do
    run = IngestionRun.create!(%{type: :backfill, started_at: DateTime.utc_now()})

    defaults = %{
      channel_id: channel.id,
      revision: "abc123",
      base_url: "https://releases.nixos.org/nixpkgs/nixpkgs-21.11pre329302.d14ae62671f",
      released_at: DateTime.utc_now(),
      active_steps: [:create_revision, :load_packages, :finalize],
      sequence: 0,
      ingestion_run_id: run.id
    }

    Pipeline.create!(Map.merge(defaults, attrs))
  end

  defp redirected_to_auth?(%{status: 302} = conn), do: redirected_to(conn) in ["/sign-in", "/"]
  defp redirected_to_auth?(_conn), do: false

  defp admin! do
    user = register_via_github!()

    Tracker.Repo.update_all(
      from(u in "users", where: u.github_id == ^user.github_id),
      set: [roles: ["user", "admin"]]
    )

    register_via_github!(%{"id" => user.github_id, "login" => user.github_username})
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Helpers.store_in_session(user)
  end

  defp register_via_github!(overrides \\ %{}) do
    user_info =
      Map.merge(
        %{
          "id" => System.unique_integer([:positive]),
          "login" => "user_#{System.unique_integer([:positive])}"
        },
        overrides
      )

    User
    |> Ash.Changeset.for_create(:register_with_github,
      user_info: user_info,
      oauth_tokens: %{"access_token" => "tok"}
    )
    |> Ash.create!(authorize?: false)
  end
end
