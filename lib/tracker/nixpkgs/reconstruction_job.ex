defmodule Tracker.Nixpkgs.ReconstructionJob do
  @moduledoc """
  A claim by an external nix-capable worker to reconstruct an expired
  `comparison.zip` for a merged PR via the nixpkgs eval workflow.

  Jobs are created only by `:claim`. Workers either submit a result —
  validated, written to the artifact cache, and marked `:succeeded` —
  or fail the job. Stale claimed jobs (`lease_expires_at` in the past)
  are reclaimable: a subsequent `:claim` for the same change demotes
  the stale row to `:failed` before inserting a fresh one.

  Authoritative authorization happens via the resource policies; the
  HTTP pipeline gates a redundant defense in depth.
  """

  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Nixpkgs,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "reconstruction_jobs"
    repo Tracker.Repo

    references do
      reference :change, on_delete: :delete
    end

    custom_indexes do
      index [:change_id],
        unique: true,
        where: "status = 'claimed'",
        name: "reconstruction_jobs_one_claimed_per_change_index"
    end
  end

  json_api do
    type "reconstruction_job"

    routes do
      base "/reconstruction_jobs"

      route :post, "/claim", :claim
      route :post, "/:id/fail", :fail
    end
  end

  code_interface do
    define :claim
    define :fail, args: [:id, :lease_token, :reason, :detail]
    define :submit_result, args: [:id, :lease_token, :zip_bytes]
    define :get_by_id, action: :read, get_by: [:id]
  end

  actions do
    defaults [:read]

    create :create_internal do
      description "Internal create used by :claim — not exposed externally."
      accept [:change_id, :claimed_at, :lease_expires_at, :lease_token, :status]
    end

    update :update_internal do
      description "Internal update used by :claim/:fail/:submit_result — not exposed externally."
      accept [:status, :last_error, :lease_token, :lease_expires_at, :claimed_at]
    end

    action :claim, :map do
      description "Atomically pick the oldest eligible expired-artifact merged Change and create a claim job for it."

      run Tracker.Nixpkgs.ReconstructionJob.Claim
    end

    action :fail, :map do
      description "Mark a claimed job as :failed."
      argument :id, :uuid, allow_nil?: false
      argument :lease_token, :string, allow_nil?: false
      argument :reason, :string, allow_nil?: false
      argument :detail, :string

      run Tracker.Nixpkgs.ReconstructionJob.Fail
    end

    action :submit_result, :map do
      description "Validate and persist a reconstruction result, then enqueue artifact refresh."
      argument :id, :uuid, allow_nil?: false
      argument :lease_token, :string, allow_nil?: false
      argument :zip_bytes, :term, allow_nil?: false

      run Tracker.Nixpkgs.ReconstructionJob.SubmitResult
    end
  end

  policies do
    bypass action(:claim) do
      authorize_if {Tracker.Accounts.Checks.ActorHasRole, role: :reconstruction_worker}
    end

    bypass action(:fail) do
      authorize_if {Tracker.Accounts.Checks.ActorHasRole, role: :reconstruction_worker}
    end

    bypass action(:submit_result) do
      authorize_if {Tracker.Accounts.Checks.ActorHasRole, role: :reconstruction_worker}
    end

    bypass action_type(:read) do
      authorize_if {Tracker.Accounts.Checks.ActorHasRole, role: :reconstruction_worker}
    end

    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :claimed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :lease_expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :lease_token, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :claimed
      constraints one_of: [:claimed, :succeeded, :failed]
    end

    attribute :last_error, :string do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :change, Tracker.Nixpkgs.Change,
      allow_nil?: false,
      attribute_type: :integer,
      public?: true
  end
end
