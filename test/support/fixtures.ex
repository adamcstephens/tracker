defmodule Tracker.Fixtures do
  @moduledoc """
  Test helpers for setting up ingestion data.
  """

  @doc """
  Registers a user via the GitHub strategy, returning the persisted user.
  """
  def register_user!(overrides \\ %{}) do
    user_info =
      Map.merge(
        %{
          "id" => System.unique_integer([:positive]),
          "login" => "user_#{System.unique_integer([:positive])}"
        },
        overrides
      )

    Tracker.Accounts.User
    |> Ash.Changeset.for_create(:register_with_github,
      user_info: user_info,
      oauth_tokens: %{"access_token" => "tok"}
    )
    |> Ash.create!(authorize?: false)
  end

  @doc "Creates a package with a unique attribute name."
  def package!(attribute \\ nil) do
    attribute = attribute || "pkg-#{System.unique_integer([:positive])}"
    Tracker.Nixpkgs.Package.create!(%{attribute: attribute})
  end

  @doc "Creates an active channel with a unique name."
  def channel!(name \\ nil) do
    name = name || "chan-#{System.unique_integer([:positive])}"
    Tracker.Nixpkgs.Channel.create!(%{name: name, display_name: name, status: :active})
  end

  @doc "Creates a merged change with a unique PR number."
  def change!(number \\ nil) do
    number = number || System.unique_integer([:positive])

    Tracker.Nixpkgs.Change.bulk_upsert_all([
      %{
        number: number,
        title: "change ##{number}",
        state: :merged,
        author: "tester",
        base_ref: "master",
        url: "https://github.com/NixOS/nixpkgs/pull/#{number}"
      }
    ])

    Tracker.Nixpkgs.Change.get_by_number!(number)
  end

  @doc """
  Loads options data into the database for a channel revision.

  Accepts a raw options map (as from options.json) and a channel revision.
  Upserts options, option revisions, files, and option-revision-file links.
  """
  def load_options(options_map, channel_revision) do
    option_records =
      Enum.map(options_map, fn {name, _entry} -> %{name: name} end)

    option_id_map = Tracker.Nixpkgs.Option.bulk_upsert_all(option_records)

    revision_records =
      Enum.map(options_map, fn {name, entry} ->
        %{
          option_id: Map.fetch!(option_id_map, name),
          channel_revision_id: channel_revision.id,
          description: entry["description"],
          type: entry["type"],
          default: extract_text(entry["default"]),
          example: extract_text(entry["example"]),
          read_only: entry["readOnly"] || false,
          loc: entry["loc"],
          related_packages: entry["relatedPackages"]
        }
      end)

    option_revision_id_map = Tracker.Nixpkgs.OptionRevision.bulk_insert_all(revision_records)

    declaration_paths =
      options_map
      |> Enum.flat_map(fn {_name, entry} -> entry["declarations"] || [] end)
      |> Enum.map(&Tracker.Nixpkgs.File.normalize_path/1)
      |> Enum.uniq()

    file_id_map = Tracker.Nixpkgs.File.bulk_upsert_all(declaration_paths)

    option_revision_file_records =
      options_map
      |> Enum.flat_map(fn {name, entry} ->
        option_id = Map.fetch!(option_id_map, name)
        revision_id = Map.fetch!(option_revision_id_map, option_id)

        (entry["declarations"] || [])
        |> Enum.map(&Tracker.Nixpkgs.File.normalize_path/1)
        |> Enum.uniq()
        |> Enum.map(fn path ->
          %{option_revision_id: revision_id, file_id: Map.fetch!(file_id_map, path)}
        end)
      end)

    Tracker.Nixpkgs.OptionRevisionFile.bulk_insert_all(option_revision_file_records)

    :ok
  end

  defp extract_text(%{"text" => text}), do: text
  defp extract_text(_), do: nil
end
