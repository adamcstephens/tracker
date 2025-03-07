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
        apply_on_password_change?(true)
      end
    end

    strategies do
      github do
        client_id Tracker.Secrets
        redirect_uri Tracker.Secrets
        client_secret Tracker.Secrets
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
      upsert_identity :unique_email

      change AshAuthentication.GenerateTokenChange

      change fn changeset, _ ->
        user_info = Ash.Changeset.get_argument(changeset, :user_info) |> dbg()

        Ash.Changeset.change_attributes(changeset, Map.take(user_info, ["email"]))
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

  attributes do
    uuid_v7_primary_key :id

    attribute :oidc_id, :string do
      allow_nil? false
    end

    attribute :email, :string

    attribute :github_username, :string do
      allow_nil? false
    end
  end
end
