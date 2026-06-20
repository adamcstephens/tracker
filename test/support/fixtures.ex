defmodule Tracker.Fixtures do
  @moduledoc """
  Test helpers for setting up ingestion data.
  """
  require Ash.Query

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

  @doc "Creates a channel revision with a unique git revision hash."
  def channel_revision!(channel \\ nil, attrs \\ %{}) do
    channel = channel || channel!()

    base = %{
      revision: "rev-#{System.unique_integer([:positive])}",
      released_at: DateTime.utc_now(:second),
      channel_id: channel.id
    }

    Tracker.Nixpkgs.ChannelRevision.create!(Map.merge(base, attrs))
  end

  @doc """
  Opens/updates package spans for a revision via the engine, mirroring
  ingestion. `package_versions` is a list of `{package, version}` or
  `{package, payload_map}`.

  Defaults to `complete?: false` so it only touches the listed packages — a
  partial set never closes other packages' open spans. Use `remove_package!/2`
  to model a removal, or pass `complete?: true` when applying a channel's full
  set. Returns the engine's `%{added, changed, removed, left}` counts.
  """
  def apply_package_revision!(channel_revision, package_versions, opts \\ []) do
    incoming =
      Enum.map(package_versions, fn
        {package, version} when is_binary(version) ->
          package_payload(package, %{version: version})

        {package, %{} = attrs} ->
          package_payload(package, attrs)
      end)

    Tracker.Nixpkgs.SpanEngine.diff_and_apply(
      Tracker.Nixpkgs.PackageSpan.spec(),
      channel_revision.channel_id,
      channel_revision.released_at,
      incoming,
      Keyword.put_new(opts, :complete?, false)
    )
  end

  @doc """
  Closes a package's open span in the revision's channel at its `released_at`,
  modelling a removal (the package is absent from that revision onward).
  """
  def remove_package!(channel_revision, package) do
    open_ids =
      package.id
      |> Tracker.Nixpkgs.PackageSpan.by_package!(channel_revision.channel_id)
      |> Enum.filter(
        &match?(%Postgrex.Range{upper: upper} when upper in [nil, :unbound], &1.valid)
      )
      |> Enum.map(& &1.id)

    unless open_ids == [] do
      Tracker.Nixpkgs.PackageSpan
      |> Ash.Query.filter(id in ^open_ids)
      |> Ash.bulk_update!(:close, %{closed_at: channel_revision.released_at},
        strategy: [:atomic],
        authorize?: false,
        return_records?: false
      )
    end

    :ok
  end

  defp package_payload(package, attrs) do
    Tracker.Nixpkgs.PackageSpan.payload_columns()
    |> Map.new(&{&1, nil})
    |> Map.put(:package_id, package.id)
    |> Map.merge(attrs)
  end

  @doc "Records a notification for a user via the fan-out path, returning the row."
  def notification!(user, overrides \\ %{}) do
    dedup_key = "dk-#{System.unique_integer([:positive])}"

    row =
      Map.merge(
        %{
          user_id: user.id,
          type: :channel_revision_published,
          occurred_at: DateTime.utc_now(:second),
          dedup_key: dedup_key
        },
        overrides
      )

    :ok = Tracker.Notifications.Notification.fanout([row])

    Tracker.Notifications.Notification.for_user!(actor: user)
    |> Enum.find(&(&1.dedup_key == dedup_key))
  end

  @doc "Records a change branch, optionally linked to a channel revision."
  def change_branch!(change, branch_name, channel_revision \\ nil) do
    Tracker.Nixpkgs.ChangeBranch.create!(%{
      change_id: change.id,
      branch_name: branch_name,
      channel_revision_id: channel_revision && channel_revision.id
    })
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
