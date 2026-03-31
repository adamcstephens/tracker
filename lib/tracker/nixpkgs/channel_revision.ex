defmodule Tracker.Nixpkgs.ChannelRevision do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "channel_revisions"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :find, args: [:channel, :revision]
    define :create
    define :list_by_channel, args: [:channel]
    define :record_result
    define :by_channel, args: [:channel]
    define :distinct_channels
    define :find_by_short_hash, args: [:channel, :short_hash]
    define :find_by_hash, args: [:hash]
  end

  actions do
    defaults [:read]

    read :find do
      get? true

      argument :channel, :string do
        allow_nil? false
      end

      argument :revision, :string do
        allow_nil? false
      end

      filter expr(channel == ^arg(:channel) and revision == ^arg(:revision))
    end

    create :create do
      primary? true
      accept [:channel, :revision, :released_at, :previous_channel_revision_id]
      upsert? true
      upsert_identity :unique_channel_revision
      upsert_fields [:released_at, :previous_channel_revision_id, :updated_at]
    end

    read :list_by_channel do
      argument :channel, :string do
        allow_nil? false
      end

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: [{:released_at, :desc}])
      filter expr(channel == ^arg(:channel))
    end

    update :record_result do
      accept [:result]
    end

    read :by_channel do
      argument :channel, :string do
        allow_nil? false
      end

      filter expr(channel == ^arg(:channel))
    end

    read :distinct_channels do
      prepare build(distinct: [:channel], sort: [:channel])
    end

    read :find_by_short_hash do
      get? true

      argument :channel, :string do
        allow_nil? false
      end

      argument :short_hash, :string do
        allow_nil? false
      end

      filter expr(
               channel == ^arg(:channel) and
                 fragment("? LIKE ? || '%'", revision, ^arg(:short_hash))
             )
    end

    read :find_by_hash do
      get? true

      argument :hash, :string do
        allow_nil? false
      end

      filter expr(fragment("? LIKE ? || '%'", revision, ^arg(:hash)))
    end
  end

  attributes do
    integer_primary_key :id

    attribute :channel, :string do
      allow_nil? false
      public? true
    end

    attribute :revision, :string do
      allow_nil? false
      public? true
    end

    attribute :result, :atom, constraints: [one_of: [:success, :partial_success, :error]]

    attribute :released_at, :utc_datetime, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :previous_channel_revision, __MODULE__ do
      attribute_type :integer
      allow_nil? true
    end
  end

  identities do
    identity :unique_channel_revision, [:channel, :revision]
  end

  @doc """
  Returns version changes between two channel revisions as a list of maps
  with `:attribute`, `:old_version`, and `:new_version` keys.

  Only includes packages where the version differs (including added/removed).
  """
  def version_diff(old_rev_id, new_rev_id) do
    %{rows: rows} =
      Tracker.Repo.query!(
        """
        WITH old_revs AS (
          SELECT package_id, version FROM package_revisions WHERE channel_revision_id = $1
        ),
        new_revs AS (
          SELECT package_id, version FROM package_revisions WHERE channel_revision_id = $2
        )
        SELECT p.attribute, o.version, n.version
        FROM old_revs o
        FULL OUTER JOIN new_revs n ON o.package_id = n.package_id
        JOIN packages p ON p.id = COALESCE(n.package_id, o.package_id)
        WHERE o.version IS DISTINCT FROM n.version
        ORDER BY p.attribute
        """,
        [old_rev_id, new_rev_id]
      )

    Enum.map(rows, fn [attribute, old_version, new_version] ->
      %{attribute: attribute, old_version: old_version, new_version: new_version}
    end)
  end
end
