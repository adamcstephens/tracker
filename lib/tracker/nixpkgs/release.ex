defmodule Tracker.Nixpkgs.Release do
  @moduledoc """
  Durable ledger of known channel releases from the nix-releases S3 bucket.

  Rows are immutable facts derived from S3 listings; revisions are resolved
  once, globally. The table is safe to truncate — `refresh/2` rebuilds it
  from S3, with the write-through `S3Cache` absorbing revision fetches.
  """

  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Nixpkgs,
    data_layer: AshPostgres.DataLayer

  alias Tracker.Nixpkgs.{BulkCreate, Channel, S3Cache}

  @releases_base_url "https://releases.nixos.org"

  # Default floor: 2020-03-27, where packages.json.br first appears.
  @default_release_cutoff ~U[2020-03-27T00:00:00Z]

  @resolve_concurrency 10

  postgres do
    table "releases"
    repo Tracker.Repo

    custom_indexes do
      index [:channel_id, :released_at]
    end
  end

  code_interface do
    define :upsert
    define :by_channel, args: [:channel_id]
    define :previous_before, args: [:channel_id, :released_at], not_found_error?: false
    define :find_by_revision, args: [:channel_id, :revision], not_found_error?: false
    define :newest, args: [:channel_id], not_found_error?: false
    define :unresolved_in, args: [:channel_id, :base_urls]
    define :without_pipeline, args: [:channel_id]
    define :resolve, args: [:revision]
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true
      accept [:channel_id, :base_url, :released_at, :revision]
      upsert? true
      upsert_identity :unique_channel_base_url
      upsert_fields [:released_at, :updated_at]
    end

    read :by_channel do
      argument :channel_id, :integer, allow_nil?: false

      prepare build(sort: [released_at: :desc])
      filter expr(channel_id == ^arg(:channel_id))
    end

    read :previous_before do
      description "The release with the greatest released_at below the given one."
      get? true

      argument :channel_id, :integer, allow_nil?: false
      argument :released_at, :utc_datetime, allow_nil?: false

      prepare build(sort: [released_at: :desc], limit: 1)
      filter expr(channel_id == ^arg(:channel_id) and released_at < ^arg(:released_at))
    end

    read :find_by_revision do
      get? true

      argument :channel_id, :integer, allow_nil?: false
      argument :revision, :string, allow_nil?: false

      filter expr(channel_id == ^arg(:channel_id) and revision == ^arg(:revision))
    end

    read :newest do
      get? true

      argument :channel_id, :integer, allow_nil?: false

      prepare build(sort: [released_at: :desc], limit: 1)
      filter expr(channel_id == ^arg(:channel_id))
    end

    read :unresolved_in do
      argument :channel_id, :integer, allow_nil?: false
      argument :base_urls, {:array, :string}, allow_nil?: false

      filter expr(
               channel_id == ^arg(:channel_id) and is_nil(revision) and
                 base_url in ^arg(:base_urls)
             )
    end

    read :without_pipeline do
      description "Known releases on a channel with no non-failed ingestion pipeline, oldest first."

      argument :channel_id, :integer, allow_nil?: false

      prepare build(sort: [released_at: :asc])

      filter expr(
               channel_id == ^arg(:channel_id) and
                 not exists(
                   Tracker.Ingestion.Pipeline,
                   channel_id == parent(channel_id) and revision == parent(revision) and
                     status != :failed
                 )
             )
    end

    update :resolve do
      argument :revision, :string, allow_nil?: false

      change set_attribute(:revision, arg(:revision))
    end
  end

  attributes do
    integer_primary_key :id

    attribute :base_url, :string do
      allow_nil? false
      public? true
    end

    attribute :released_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :revision, :string do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :channel, Tracker.Nixpkgs.Channel do
      attribute_type :integer
      allow_nil? false
    end
  end

  identities do
    identity :unique_channel_base_url, [:channel_id, :base_url]
  end

  # -- Refresh --

  @doc "The configured default release cutoff (overridable via app env)."
  def default_cutoff,
    do: Application.get_env(:tracker, :release_cutoff_date, @default_release_cutoff)

  @doc """
  Refreshes `channel`'s release ledger from S3, in the caller's process.

  Lists the channel's releases, upserts them (never clobbering an already
  resolved revision), then resolves missing revisions with bounded
  concurrency through the write-through `S3Cache`.

  Options:
    - `from` - oldest `released_at` to include; overrides the default cutoff so
      historical backfills can reach earlier than the conservative default.
    - `until` - newest `released_at` to include; bounds a backfill to a window so
      the earliest history can be ingested without resolving every later release.
    - `releases_fetcher` - 1-arity function from channel name to a list of
      `%{base_url, released_at, revision?}` maps. Defaults to fetching from S3.
      Useful in tests.
  """
  def refresh(%Channel{} = channel, opts \\ []) do
    from = Keyword.get(opts, :from)
    until = Keyword.get(opts, :until)

    fetcher =
      Keyword.get(opts, :releases_fetcher, fn name ->
        name |> fetch_releases() |> parse_releases(from, until)
      end)

    listed = fetcher.(channel.name)

    listed
    |> Enum.map(&Map.put(&1, :channel_id, channel.id))
    |> BulkCreate.run!(__MODULE__, :upsert, 500)

    resolve_missing_revisions(channel.id, listed)

    :ok
  end

  defp resolve_missing_revisions(_channel_id, []), do: :ok

  defp resolve_missing_revisions(channel_id, listed) do
    revisions_by_url =
      for release <- listed, Map.get(release, :revision) != nil, into: %{} do
        {release.base_url, release.revision}
      end

    req = S3Cache.new()

    channel_id
    |> unresolved_in!(Enum.map(listed, & &1.base_url))
    |> Task.async_stream(
      fn release ->
        case Map.get(revisions_by_url, release.base_url) || fetch_revision(req, release.base_url) do
          nil -> :ok
          revision -> resolve!(release, revision)
        end
      end,
      max_concurrency: @resolve_concurrency,
      timeout: :timer.minutes(1)
    )
    |> Stream.run()
  end

  defp fetch_revision(req, base_url) do
    case Req.get(req, url: base_url <> "/git-revision") do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        String.trim(body)

      _ ->
        nil
    end
  end

  # -- S3 listing --

  @doc false
  def parse_releases(contents, from \\ nil, until \\ nil) do
    from = from || default_cutoff()

    contents
    |> List.wrap()
    |> Enum.map(fn %{"Key" => key, "LastModified" => last_modified} ->
      {:ok, released_at, _offset} = DateTime.from_iso8601(last_modified)

      %{base_url: "#{@releases_base_url}/#{key}", released_at: released_at}
    end)
    |> Enum.reject(fn release ->
      DateTime.before?(release.released_at, from) or
        (until != nil and DateTime.after?(release.released_at, until))
    end)
  end

  # nixpkgs-unstable has no grouping directory: its snapshots are top-level
  # siblings under `nixpkgs/` (`nixpkgs/nixpkgs-<X.Y>pre<rev>.<sha>/`),
  # interleaved with the darwin channels and pre-2020 tags. So it lists the
  # whole `nixpkgs/` tree and relies on `release_key?/2` to keep only its own
  # snapshots. Every other channel lives under a dedicated prefix.
  @doc false
  def s3_prefix("nixos-" <> rest), do: "nixos/#{rest}/"
  def s3_prefix("nixpkgs-unstable"), do: "nixpkgs/"
  def s3_prefix("nixpkgs-" <> rest), do: "nixpkgs/#{rest}/"
  def s3_prefix(channel), do: "#{channel}/"

  @nixpkgs_unstable_snapshot ~r{^nixpkgs/nixpkgs-\d+\.\d+pre\d+\.[0-9a-f]+$}

  @doc false
  def release_key?("nixpkgs-unstable", key),
    do: Regex.match?(@nixpkgs_unstable_snapshot, key)

  def release_key?(_channel, _key), do: true

  defp fetch_releases(channel) do
    req_s3 = Req.new() |> ReqS3.attach()
    fetch_releases(req_s3, channel, nil, [])
  end

  defp fetch_releases(req_s3, channel, marker, acc) do
    params =
      [delimiter: "/", prefix: s3_prefix(channel)]
      |> then(fn p -> if marker, do: Keyword.put(p, :marker, marker), else: p end)

    resp = Req.get!(req_s3, url: "s3://nix-releases", params: params)
    body = resp.body["ListBucketResult"]

    contents =
      body["Contents"]
      |> List.wrap()
      |> Enum.filter(&release_key?(channel, &1["Key"]))

    all_contents = acc ++ contents

    if body["IsTruncated"] == "true" do
      fetch_releases(req_s3, channel, body["NextMarker"], all_contents)
    else
      all_contents
    end
  end
end
