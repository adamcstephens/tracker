defmodule Tracker.Accounts.User.Role do
  use Ash.Type.Enum, values: [:user, :admin, :maintainer, :committer]
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

  actions do
    defaults [:read]

    create :register_with_github do
      argument :user_info, :map, allow_nil?: false
      argument :oauth_tokens, :map, allow_nil?: false
      upsert? true
      upsert_identity :unique_github_id

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
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
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
  end

  identities do
    identity :unique_github_id, [:github_id]
    identity :unique_github_username, [:github_username]
  end

  def has_role?(%{roles: roles}, role) when is_list(roles) and is_atom(role) do
    role in roles
  end
end
