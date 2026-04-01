defmodule Tracker.Nixpkgs.OptionRevision do
  use Ash.Resource, otp_app: :tracker, domain: Tracker.Nixpkgs, data_layer: AshPostgres.DataLayer

  postgres do
    table "option_revisions"
    repo Tracker.Repo
  end

  code_interface do
    define :read
    define :load
  end

  actions do
    defaults [:read]

    create :load do
      accept [
        :option_id,
        :channel_revision_id,
        :description,
        :type,
        :default,
        :example,
        :read_only,
        :loc,
        :declarations,
        :related_packages
      ]

      upsert? true
      upsert_identity :unique_option_revision

      upsert_fields [
        :description,
        :type,
        :default,
        :example,
        :read_only,
        :loc,
        :declarations,
        :related_packages,
        :updated_at
      ]
    end
  end

  attributes do
    integer_primary_key :id

    attribute :description, :string, public?: true
    attribute :type, :string, public?: true
    attribute :default, :string, public?: true
    attribute :example, :string, public?: true

    attribute :read_only, :boolean do
      default false
      public? true
    end

    attribute :loc, {:array, :string}, public?: true
    attribute :declarations, {:array, :string}, public?: true
    attribute :related_packages, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :option, Tracker.Nixpkgs.Option, attribute_type: :integer, allow_nil?: false

    belongs_to :channel_revision, Tracker.Nixpkgs.ChannelRevision,
      attribute_type: :integer,
      allow_nil?: false
  end

  identities do
    identity :unique_option_revision, [:channel_revision_id, :option_id]
  end

  # 12 columns: option_id, channel_revision_id, description, type, default, example,
  #             read_only, loc, declarations, related_packages, inserted_at, updated_at
  @insert_cols 12
  @max_rows div(65_535, @insert_cols)

  @doc """
  Computes the set difference of option_ids between two channel revisions.

  Returns `{added_ids, removed_ids}`.
  """
  def diff_option_ids(new_id, prev_id) do
    {:ok, %{rows: rows}} =
      Tracker.Repo.query(
        """
        SELECT option_id, 'added' AS type FROM (
          SELECT option_id FROM option_revisions WHERE channel_revision_id = $1
          EXCEPT
          SELECT option_id FROM option_revisions WHERE channel_revision_id = $2
        ) added
        UNION ALL
        SELECT option_id, 'removed' AS type FROM (
          SELECT option_id FROM option_revisions WHERE channel_revision_id = $2
          EXCEPT
          SELECT option_id FROM option_revisions WHERE channel_revision_id = $1
        ) removed
        """,
        [new_id, prev_id]
      )

    Enum.split_with(rows, fn [_, type] -> type == "added" end)
    |> then(fn {added, removed} ->
      {Enum.map(added, &hd/1), Enum.map(removed, &hd/1)}
    end)
  end

  def bulk_insert_all(records) do
    now = DateTime.utc_now(:second)

    records
    |> Stream.map(fn record ->
      record
      |> Map.put(:inserted_at, now)
      |> Map.put(:updated_at, now)
    end)
    |> Stream.chunk_every(@max_rows)
    |> Enum.each(fn chunk ->
      Tracker.Repo.insert_all(
        "option_revisions",
        chunk,
        on_conflict:
          {:replace,
           [
             :description,
             :type,
             :default,
             :example,
             :read_only,
             :loc,
             :declarations,
             :related_packages,
             :updated_at
           ]},
        conflict_target: [:channel_revision_id, :option_id]
      )
    end)
  end
end
