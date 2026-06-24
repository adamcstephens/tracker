defmodule Tracker.Nixpkgs.ChannelRevision do
  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Nixpkgs,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

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
    define :by_channel_asc, args: [:channel_id]
    define :by_released_ats, args: [:channel_id, :released_ats]
    define :by_ids, args: [:ids]
    define :get_by_id, action: :read, get_by: [:id]
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
      require_atomic? false

      change after_transaction(fn
               _changeset, {:ok, revision}, _context ->
                 if revision.result == :success do
                   %{channel_revision_id: revision.id}
                   |> Tracker.Notifications.NotificationFanoutRevisionWorker.new()
                   |> Oban.insert!()
                 end

                 {:ok, revision}

               _changeset, {:error, error}, _context ->
                 {:error, error}
             end)
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

    read :by_channel_asc do
      argument :channel_id, :integer, allow_nil?: false

      prepare build(sort: [{:released_at, :asc}])
      filter expr(channel_id == ^arg(:channel_id))
    end

    read :by_released_ats do
      description "Revisions on a channel matching specific release timestamps."
      argument :channel_id, :integer, allow_nil?: false
      argument :released_ats, {:array, :utc_datetime}, allow_nil?: false

      filter expr(channel_id == ^arg(:channel_id) and released_at in ^arg(:released_ats))
    end

    read :by_ids do
      description "Revisions matching a set of ids."
      argument :ids, {:array, :integer}, allow_nil?: false

      filter expr(id in ^arg(:ids))
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

  pub_sub do
    module Phoenix.PubSub
    name Tracker.PubSub
    prefix "channel_revisions"

    publish :create, [[:channel_id, "any"], "created"]
    publish :record_result, [[:channel_id, "any"], "completed"]
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
  end

  identities do
    identity :unique_channel_revision, [:channel_id, :revision]
  end

  defmodule VersionDiff do
    use TypedStruct

    typedstruct enforce: true do
      field :attribute, String.t()
      field :old_version, String.t() | nil
      field :new_version, String.t() | nil
    end
  end

  defmodule RevisionDiff do
    use TypedStruct

    typedstruct enforce: true do
      field :package_events, list()
      field :version_changes, list(Tracker.Nixpkgs.ChannelRevision.VersionDiff.t())
      field :option_events, list()
      field :option_metadata_changes, list()
    end
  end

  @doc """
  Computes the four diff lists between two channel revisions on the same
  channel: package events, version changes, option events, and option
  metadata changes.
  """
  def diff_between(from_rev, to_rev) do
    pkg = Tracker.Nixpkgs.PackageHistory.diff_between(to_rev, from_rev.released_at)
    opt = Tracker.Nixpkgs.OptionHistory.diff_between(to_rev, from_rev.released_at)

    %RevisionDiff{
      package_events: pkg.events,
      version_changes: pkg.version_changes,
      option_events: opt.events,
      option_metadata_changes: opt.metadata_changes
    }
  end

  @doc """
  Version changes between two channel revisions as `VersionDiff` structs — only
  packages whose version differs (added/removed included), sorted by attribute.
  """
  def version_diff(from_rev, to_rev) do
    Tracker.Nixpkgs.PackageHistory.diff_between(to_rev, from_rev.released_at).version_changes
  end
end
