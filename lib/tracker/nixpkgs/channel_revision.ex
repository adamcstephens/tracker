defmodule Tracker.Nixpkgs.ChannelRevision do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "channel_revisions"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :find, args: [:channel_id, :revision]
    define :create
    define :list_by_channel, args: [:channel_id]
    define :record_result
    define :record_options_result
    define :by_channel, args: [:channel_id]
    define :find_by_hash, args: [:hash]
    define :find_by_channel_hash, args: [:channel_id, :hash]
    define :latest_by_channel, args: [:channel_id]
    define :without_options, args: [:channel_id]
  end

  actions do
    defaults [:read]

    read :find do
      get? true

      argument :channel_id, :integer do
        allow_nil? false
      end

      argument :revision, :string do
        allow_nil? false
      end

      filter expr(channel_id == ^arg(:channel_id) and revision == ^arg(:revision))
    end

    create :create do
      primary? true
      accept [:revision, :released_at, :previous_channel_revision_id, :channel_id]
      upsert? true
      upsert_identity :unique_channel_revision
      upsert_fields [:released_at, :previous_channel_revision_id, :updated_at]
    end

    read :list_by_channel do
      argument :channel_id, :integer do
        allow_nil? false
      end

      pagination do
        offset? true
        countable true
        default_limit 15
      end

      prepare build(sort: [{:released_at, :desc}])
      filter expr(channel_id == ^arg(:channel_id))
    end

    update :record_result do
      accept [:result]
    end

    update :record_options_result do
      accept [:options_result]
    end

    read :by_channel do
      argument :channel_id, :integer do
        allow_nil? false
      end

      filter expr(channel_id == ^arg(:channel_id))
    end

    read :without_options do
      argument :channel_id, :integer, allow_nil?: false

      prepare build(sort: [{:released_at, :asc}])

      filter expr(
               channel_id == ^arg(:channel_id) and
                 result == :success and
                 not exists(option_revisions, true)
             )
    end

    read :latest_by_channel do
      get? true

      argument :channel_id, :integer, allow_nil?: false

      prepare build(sort: [{:released_at, :desc}], limit: 1)
      filter expr(channel_id == ^arg(:channel_id) and options_result == :success)
    end

    read :find_by_channel_hash do
      get? true

      argument :channel_id, :integer do
        allow_nil? false
      end

      argument :hash, :string do
        allow_nil? false
      end

      filter expr(
               channel_id == ^arg(:channel_id) and
                 fragment("? LIKE ? || '%'", revision, ^arg(:hash))
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

    attribute :revision, :string do
      allow_nil? false
      public? true
    end

    attribute :result, :atom, constraints: [one_of: [:success, :partial_success, :error]]

    attribute :options_result, :atom,
      constraints: [one_of: [:success, :error]],
      public?: true

    attribute :released_at, :utc_datetime, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :channel, Tracker.Nixpkgs.Channel do
      attribute_type :integer
      allow_nil? false
    end

    belongs_to :previous_channel_revision, __MODULE__ do
      attribute_type :integer
      allow_nil? true
    end

    has_many :option_revisions, Tracker.Nixpkgs.OptionRevision
  end

  identities do
    identity :unique_channel_revision, [:channel_id, :revision]
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
