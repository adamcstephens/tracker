defmodule Tracker.Notifications do
  use Ash.Domain, otp_app: :tracker

  resources do
    resource Tracker.Notifications.PackageSubscription
    resource Tracker.Notifications.ChannelSubscription
    resource Tracker.Notifications.ChangeSubscription
    resource Tracker.Notifications.Notification
  end
end
