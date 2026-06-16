defmodule Tracker.Nixpkgs do
  use Ash.Domain, otp_app: :tracker, extensions: [AshAdmin.Domain, AshJsonApi.Domain]

  admin do
    show? true
    show_resources [Tracker.Nixpkgs.Channel]
  end

  json_api do
    authorize? true
  end

  resources do
    resource Tracker.Nixpkgs.Channel
    resource Tracker.Nixpkgs.PackageFamily
    resource Tracker.Nixpkgs.PackageVariantGroup
    resource Tracker.Nixpkgs.Package
    resource Tracker.Nixpkgs.PackageRevision
    resource Tracker.Nixpkgs.ChannelRevision
    resource Tracker.Nixpkgs.Maintainer
    resource Tracker.Nixpkgs.Team
    resource Tracker.Nixpkgs.PackageMaintainer
    resource Tracker.Nixpkgs.PackageTeam
    resource Tracker.Nixpkgs.TeamMember
    resource Tracker.Nixpkgs.PackageEvent
    resource Tracker.Nixpkgs.Option
    resource Tracker.Nixpkgs.OptionRevision
    resource Tracker.Nixpkgs.OptionEvent
    resource Tracker.Nixpkgs.OptionPackage
    resource Tracker.Nixpkgs.File
    resource Tracker.Nixpkgs.OptionRevisionFile
    resource Tracker.Nixpkgs.Change
    resource Tracker.Nixpkgs.ChangePackage
    resource Tracker.Nixpkgs.ChangeBranch
    resource Tracker.Nixpkgs.ChangeFile
    resource Tracker.Nixpkgs.ChangeReconcileSkip
    resource Tracker.Nixpkgs.ReconstructionJob
  end
end
