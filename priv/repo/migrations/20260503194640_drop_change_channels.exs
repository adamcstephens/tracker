defmodule Tracker.Repo.Migrations.DropChangeChannels do
  use Ecto.Migration

  def up do
    drop_if_exists table(:change_channels)
  end

  def down do
    create table(:change_channels, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true

      add :landed_at, :utc_datetime, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :change_id,
          references(:changes,
            column: :id,
            name: "change_channels_change_id_fkey",
            type: :bigint,
            prefix: "public"
          ),
          null: false

      add :channel_revision_id,
          references(:channel_revisions,
            column: :id,
            name: "change_channels_channel_revision_id_fkey",
            type: :bigint,
            prefix: "public"
          )

      add :channel_id,
          references(:channels,
            column: :id,
            name: "change_channels_channel_id_fkey",
            type: :bigint,
            prefix: "public"
          ),
          null: false
    end

    create unique_index(:change_channels, [:change_id, :channel_id],
             name: "change_channels_unique_change_channel_index"
           )
  end
end
