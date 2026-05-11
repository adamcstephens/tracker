defmodule Tracker.Nixpkgs.ChangeReconcileSkip do
  @moduledoc """
  Records nixpkgs `issues/N` numbers (or numbers with no `issueOrPullRequest`
  at all) that the gap reconciler has already resolved to a non-PR.

  Issues never become PRs in the GitHub number space, so once a number lands
  here it short-circuits future reconciliation runs and we don't burn API
  quota re-resolving it.
  """
  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Nixpkgs,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "change_reconcile_skips"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :numbers_in_range, args: [:lo, :hi]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:number, :kind]

      upsert? true
      upsert_identity :unique_number
      upsert_fields [:kind, :resolved_at]

      change set_attribute(:resolved_at, &DateTime.utc_now/0)
    end

    read :numbers_in_range do
      argument :lo, :integer, allow_nil?: false
      argument :hi, :integer, allow_nil?: false

      prepare build(select: [:number])
      filter expr(number >= ^arg(:lo) and number <= ^arg(:hi))
    end
  end

  attributes do
    attribute :number, :integer do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:issue, :not_found]
    end

    attribute :resolved_at, :utc_datetime do
      allow_nil? false
      default &DateTime.utc_now/0
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_number, [:number]
  end

  @doc """
  Bulk-inserts a list of skip rows (`%{number: integer, kind: :issue | :not_found}`).

  Idempotent via the `:unique_number` upsert: re-recording an existing number is a no-op
  (just refreshes `resolved_at`).
  """
  def record!(rows) when is_list(rows) do
    case rows do
      [] ->
        :ok

      _ ->
        rows
        |> Ash.bulk_create!(__MODULE__, :record,
          upsert?: true,
          upsert_identity: :unique_number,
          return_errors?: true,
          stop_on_error?: true
        )

        :ok
    end
  end
end
