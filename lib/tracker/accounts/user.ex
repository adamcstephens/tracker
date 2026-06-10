defmodule Tracker.Accounts.User.Role do
  use Ash.Type.Enum, values: [:user, :admin, :maintainer, :committer, :reconstruction_worker]
end

defmodule Tracker.Accounts.User do
  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Accounts,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication],
    data_layer: AshPostgres.DataLayer

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    strategies do
      oauth2 :github do
        client_id Tracker.Secrets
        redirect_uri Tracker.Secrets
        client_secret Tracker.Secrets
        authorization_params scope: "read:user"
        base_url "https://github.com"
        authorize_url "https://github.com/login/oauth/authorize"
        token_url "https://github.com/login/oauth/access_token"
        user_url "https://api.github.com/user"
        code_verifier true
      end
    end

    tokens do
      enabled? true
      token_resource Tracker.Accounts.Token
      signing_secret Tracker.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end
  end

  postgres do
    table "users"
    repo Tracker.Repo
  end

  code_interface do
    define :create_service_account, args: [:name, :roles]
    define :set_live_ui
    define :rotate_feed_token
    define :by_feed_token, args: [:feed_token], not_found_error?: false
  end

  actions do
    defaults [:read]

    create :create_service_account do
      description "Create a non-human user with no GitHub identity."
      argument :name, :string, allow_nil?: false
      argument :roles, {:array, Tracker.Accounts.User.Role}, allow_nil?: false

      change fn changeset, _ ->
        name = Ash.Changeset.get_argument(changeset, :name)
        roles = Ash.Changeset.get_argument(changeset, :roles)

        changeset
        |> Ash.Changeset.change_attribute(:github_username, "service:#{name}")
        |> Ash.Changeset.change_attribute(:roles, roles)
      end
    end

    create :register_with_github do
      argument :user_info, :map, allow_nil?: false
      argument :oauth_tokens, :map, allow_nil?: false
      upsert? true
      upsert_identity :unique_github_id
      upsert_fields [:github_username]

      change AshAuthentication.GenerateTokenChange

      change fn changeset, _ ->
        user_info = Ash.Changeset.get_argument(changeset, :user_info)

        mapped_info = %{
          github_id: Map.fetch!(user_info, "id"),
          github_username: Map.fetch!(user_info, "login")
        }

        Ash.Changeset.change_attributes(changeset, mapped_info)
      end
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    update :set_live_ui do
      require_atomic? false
      accept [:live_ui]
    end

    update :rotate_feed_token do
      description "Generate a fresh feed token, invalidating any existing feed URL."
      require_atomic? false
      accept []

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :feed_token,
          Tracker.Accounts.User.generate_feed_token()
        )
      end
    end

    read :by_feed_token do
      description "Look up a user by their notifications-feed token."
      get? true
      argument :feed_token, :string, allow_nil?: false, sensitive?: true
      filter expr(feed_token == ^arg(:feed_token))
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    bypass action(:create_service_account) do
      authorize_if {Tracker.Accounts.Checks.ActorHasRole, role: :admin}
    end

    bypass action(:set_live_ui) do
      authorize_if expr(id == ^actor(:id))
    end

    bypass action(:rotate_feed_token) do
      authorize_if expr(id == ^actor(:id))
    end

    policy always() do
      forbid_if always()
    end
  end

  changes do
    change fn changeset, _ ->
      Ash.Changeset.before_action(changeset, fn cs ->
        case Ash.Changeset.get_attribute(cs, :roles) do
          roles when is_list(roles) ->
            Ash.Changeset.force_change_attribute(cs, :roles, Enum.uniq(roles))

          _ ->
            cs
        end
      end)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :github_username, :string
    attribute :github_id, :integer

    attribute :roles, {:array, Tracker.Accounts.User.Role} do
      default [:user]
      allow_nil? false
      constraints min_length: 1
    end

    attribute :live_ui, :boolean do
      default true
      allow_nil? false
    end

    attribute :feed_token, :string do
      description "Opaque secret embedded in the user's personal notifications-feed URL; rotating it revokes outstanding feed URLs."
      sensitive? true
    end
  end

  relationships do
    has_many :notifications, Tracker.Notifications.Notification
  end

  aggregates do
    count :unread_notification_count, :notifications do
      filter expr(is_nil(read_at))
    end
  end

  identities do
    identity :unique_github_id, [:github_id]
    identity :unique_github_username, [:github_username]
    identity :unique_feed_token, [:feed_token]
  end

  def has_role?(%{roles: roles}, role) when is_list(roles) and is_atom(role) do
    role in roles
  end

  @doc """
  The user's unread-notification count, shown on the chrome inbox icon.
  Loaded without authorization: the User read policy forbids everything
  (sessions come through AshAuthentication's bypass), and the count is
  only ever requested for the session's own user.
  """
  def unread_notification_count(user) do
    user
    |> Ash.load!(:unread_notification_count, authorize?: false)
    |> Map.fetch!(:unread_notification_count)
  end

  @feed_token_prefix "trk_feed_"

  @doc "Prefix prepended to every notifications-feed token, recognised by secret scanners."
  def feed_token_prefix, do: @feed_token_prefix

  @doc "Generates a random notifications-feed token."
  def generate_feed_token do
    @feed_token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
