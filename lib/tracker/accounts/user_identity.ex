defmodule Tracker.Accounts.UserIdentity do
  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.UserIdentity]

  postgres do
    table "user_identities"
    repo Tracker.Repo
  end

  user_identity do
    user_resource Tracker.Accounts.User
  end

  actions do
    defaults [:read]
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end
end
