defmodule Tracker.Accounts.ApiToken do
  @moduledoc """
  Long-lived API bearer tokens, separate from AshAuthentication's user-session
  `tokens` table. Each row is one issued JWT; revocation flips `revoked_at`
  rather than inserting a sibling row.
  """

  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Accounts,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "api_tokens"
    repo Tracker.Repo

    references do
      reference :subject_user, on_delete: :delete
      reference :issued_by, on_delete: :nilify
      reference :revoked_by, on_delete: :nilify
    end
  end

  code_interface do
    define :issue, args: [:subject_user_id]
    define :list_for_actor
  end

  actions do
    defaults [:read]

    create :create_internal do
      description "Internal create used by the :issue action — not exposed externally."
      accept [:jti, :label, :expires_at, :subject_user_id, :issued_by_user_id]
    end

    action :issue, :map do
      description "Mint a JWT with purpose=api for a subject user and store its metadata."
      argument :subject_user_id, :uuid, allow_nil?: false
      argument :expires_in, :integer
      argument :label, :string

      run Tracker.Accounts.ApiToken.Issue
    end

    update :revoke do
      description "Mark this token as revoked. Idempotent on already-revoked rows."
      require_atomic? false

      change fn changeset, %{actor: actor} ->
        changeset
        |> Ash.Changeset.change_attribute(:revoked_at, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(:revoked_by_user_id, actor.id)
      end
    end

    update :touch_last_used_at do
      description "Records that this token was used. Called from BearerAuth on every accepted request."
      require_atomic? false
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
    end

    read :list_for_actor do
      description "List api tokens owned by the actor, newest first. No argument — the filter pins to the actor's id."
      filter expr(subject_user_id == ^actor(:id))
      prepare build(sort: [inserted_at: :desc])
    end
  end

  policies do
    bypass action(:issue) do
      authorize_if {Tracker.Accounts.Checks.ActorIdEqualsArg, arg: :subject_user_id}

      authorize_if {Tracker.Accounts.Checks.AdminIssuingForServiceAccount, arg: :subject_user_id}
    end

    bypass action(:revoke) do
      authorize_if {Tracker.Accounts.Checks.ActorOwnsApiToken, []}
      authorize_if {Tracker.Accounts.Checks.AdminRevokingServiceAccountApiToken, []}
    end

    bypass action(:list_for_actor) do
      authorize_if expr(not is_nil(^actor(:id)))
    end

    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :jti, :string do
      allow_nil? false
      public? true
    end

    attribute :label, :string do
      public? true
    end

    attribute :expires_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :last_used_at, :utc_datetime_usec do
      public? true
    end

    attribute :revoked_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :subject_user, Tracker.Accounts.User,
      allow_nil?: false,
      attribute_type: :uuid,
      public?: true

    belongs_to :issued_by, Tracker.Accounts.User,
      source_attribute: :issued_by_user_id,
      attribute_type: :uuid,
      public?: true

    belongs_to :revoked_by, Tracker.Accounts.User,
      source_attribute: :revoked_by_user_id,
      attribute_type: :uuid,
      public?: true
  end

  identities do
    identity :unique_jti, [:jti]
  end

  @token_prefix "trk_"

  @doc "Prefix prepended to every issued JWT, recognised by secret scanners."
  def token_prefix, do: @token_prefix

  def revoked?(%{revoked_at: nil}), do: false
  def revoked?(%{revoked_at: %DateTime{}}), do: true

  def revoke(jti, opts) do
    with {:ok, token} <- get_by_jti(jti) do
      token
      |> Ash.Changeset.for_update(:revoke, %{}, opts)
      |> Ash.update()
    end
  end

  def touch_last_used_at(jti) do
    with {:ok, token} <- get_by_jti(jti) do
      token
      |> Ash.Changeset.for_update(:touch_last_used_at, %{})
      |> Ash.update(authorize?: false)
    end
  end

  def get_by_jti(jti) when is_binary(jti) do
    require Ash.Query

    __MODULE__
    |> Ash.Query.filter(jti == ^jti)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      other -> other
    end
  end
end
