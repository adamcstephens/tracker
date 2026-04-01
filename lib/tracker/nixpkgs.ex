defmodule Tracker.Nixpkgs do
  use Ash.Domain,
    otp_app: :tracker

  require Logger

  resources do
    resource Tracker.Nixpkgs.PackageFamily
    resource Tracker.Nixpkgs.Package
    resource Tracker.Nixpkgs.PackageRevision
    resource Tracker.Nixpkgs.ChannelRevision
    resource Tracker.Nixpkgs.Maintainer
    resource Tracker.Nixpkgs.Team
    resource Tracker.Nixpkgs.PackageMaintainer
    resource Tracker.Nixpkgs.PackageTeam
    resource Tracker.Nixpkgs.TeamMember
    resource Tracker.Nixpkgs.PackageEvent
    resource Tracker.Nixpkgs.Module
    resource Tracker.Nixpkgs.Option
    resource Tracker.Nixpkgs.OptionRevision
    resource Tracker.Nixpkgs.OptionEvent
  end
end
