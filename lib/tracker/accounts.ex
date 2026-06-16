defmodule Tracker.Accounts do
  use Ash.Domain, otp_app: :tracker, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Tracker.Accounts.ApiToken
    resource Tracker.Accounts.Token
    resource Tracker.Accounts.User
    resource Tracker.Accounts.UserIdentity
  end
end
