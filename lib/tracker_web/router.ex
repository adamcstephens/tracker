defmodule TrackerWeb.Router do
  use TrackerWeb, :router

  use AshAuthentication.Phoenix.Router
  import AshAuthentication.Plug.Helpers

  import Phoenix.LiveDashboard.Router
  import Oban.Web.Router
  import AshAdmin.Router

  @dev_dashboard_on_mount [
    AshAuthentication.Phoenix.LiveSession,
    {TrackerWeb.LiveUserAuth, :admin_only}
  ]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TrackerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
    plug TrackerWeb.Plug.InteractiveUI
    plug TrackerWeb.Plug.Lens
  end

  pipeline :force_interactive do
    plug :assign_interactive
  end

  defp assign_interactive(conn, _opts), do: Plug.Conn.assign(conn, :interactive?, true)

  pipeline :require_admin do
    plug TrackerWeb.Plug.RequireRole, role: :admin, format: :browser
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  pipeline :api_reconstruction_worker do
    plug :accepts, ["json"]
    plug TrackerWeb.Plug.BearerAuth, purpose: "api"
    plug TrackerWeb.Plug.RequireRole, role: :reconstruction_worker
    plug :set_actor, :user
  end

  scope "/", TrackerWeb do
    pipe_through :browser

    get "/feeds/channels/:channel", FeedController, :channel
    get "/feeds/packages/:name", FeedController, :package
    get "/feeds/notifications/:token", FeedController, :notifications
    post "/lens", LensController, :update
    get "/channels/:channel/diff", ChannelDiffController, :resolve

    scope "/account" do
      pipe_through :force_interactive

      ash_authentication_live_session :account_routes,
        on_mount: [
          {TrackerWeb.LiveUserAuth, :live_user_required},
          TrackerWeb.InboxBadgeHook
        ] do
        live "/tokens", AccountLive.Tokens, :index
        live "/settings", AccountLive.Settings, :index
      end
    end

    ash_authentication_live_session :authenticated_routes,
      on_mount: [
        {TrackerWeb.LiveUserAuth, :live_user_optional},
        {TrackerWeb.Plug.InteractiveUI, :default},
        {TrackerWeb.LensHook, :default},
        TrackerWeb.InboxBadgeHook
      ] do
      live "/", PackageLive.Index, :index
      live "/packages", PackageLive.Index, :index
      live "/packages/:name", PackageLive.Show, :show
      live "/channels", ChannelLive.Index, :index
      live "/channels/:channel", ChannelLive.Show, :show
      live "/channels/:channel/revisions/:revision", ChannelLive.RevisionShow, :show
      live "/channels/:channel/diff/:rev_a/:rev_b", ChannelLive.Diff, :diff
      live "/options", OptionLive.Index, :index
      live "/options/:prefix", OptionLive.Show, :show
      live "/maintainers", MaintainerLive.Index, :index
      live "/maintainers/:github", MaintainerLive.Show, :show
      live "/changes", ChangeLive.Index, :index
      live "/changes/:number", ChangeLive.Show, :show
      live "/teams", TeamLive.Index, :index
      live "/teams/:short_name", TeamLive.Show, :show

      # Same live_session as the tabs above so navigation stays on the
      # websocket; the view itself enforces authentication and the
      # InteractiveUI hook treats it as force-interactive.
      scope "/inbox" do
        pipe_through :force_interactive

        live "/", InboxLive.Index, :index
      end
    end
  end

  scope "/api/json" do
    pipe_through [:api]

    forward "/swaggerui",
            OpenApiSpex.Plug.SwaggerUI,
            path: "/api/json/open_api",
            default_model_expand_depth: 4

    forward "/", TrackerWeb.AshJsonApiRouter
  end

  scope "/api/worker/json" do
    pipe_through :api_reconstruction_worker

    forward "/", TrackerWeb.WorkerAshJsonApiRouter
  end

  scope "/api/worker", TrackerWeb do
    pipe_through :api_reconstruction_worker

    post "/reconstruction_jobs/:id/result", ReconstructionJobController, :result
  end

  scope "/", TrackerWeb do
    pipe_through :browser

    auth_routes AuthController, Tracker.Accounts.User, path: "/auth"
    sign_out_route AuthController

    # Remove these if you'd like to use your own authentication views
    sign_in_route register_path: "/register",
                  reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  on_mount: [{TrackerWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    TrackerWeb.AuthOverrides,
                    AshAuthentication.Phoenix.Overrides.Default
                  ]

    # Remove this if you do not want to use the reset password feature
    reset_route auth_routes_prefix: "/auth",
                overrides: [TrackerWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]
  end

  scope "/dev" do
    pipe_through [:browser, :require_admin]

    live_dashboard "/dashboard",
      metrics: TrackerWeb.Telemetry,
      on_mount: @dev_dashboard_on_mount

    forward "/mailbox", Plug.Swoosh.MailboxPreview
    oban_dashboard "/oban", on_mount: @dev_dashboard_on_mount
  end

  scope "/admin" do
    pipe_through :browser

    ash_admin "/",
              AshAuthentication.Phoenix.LiveSession.opts(
                on_mount: [{TrackerWeb.LiveUserAuth, :admin_only}]
              )
  end
end
