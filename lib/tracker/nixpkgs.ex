defmodule Tracker.Nixpkgs do
  use Ash.Domain,
    otp_app: :tracker

  require Logger

  resources do
    resource Tracker.Nixpkgs.Package
    resource Tracker.Nixpkgs.PackageRevision
    resource Tracker.Nixpkgs.ChannelRevision
  end
end
