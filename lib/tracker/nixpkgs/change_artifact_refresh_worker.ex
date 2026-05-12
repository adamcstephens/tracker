defmodule Tracker.Nixpkgs.ChangeArtifactRefreshWorker do
  @moduledoc """
  Refreshes the ChangePackage link set for a Change from its latest
  comparison artifact, atomically replacing the existing links.

  Two reasons are supported:

    * `"merged"` — pulls the comparison from the Merge Group workflow
      run keyed by `merge_commit_sha`.
    * `"head_sha_changed"` — pulls the comparison from the open/draft
      PR's "PR" workflow run (event `pull_request_target`) keyed by
      `head_sha`. Run each time the head_sha advances so the link set
      stays current while the PR is in flight.
  """
  use Oban.Worker,
    queue: :changes,
    max_attempts: 10,
    unique: [fields: [:worker, :args], keys: [:number, :reason], period: 300]

  require Logger

  alias Tracker.GitHub.RateLimitCache
  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactCache
  alias Tracker.Nixpkgs.ChangeFile
  alias Tracker.Nixpkgs.ChangePackage
  alias Tracker.Nixpkgs.File, as: NixFile
  alias Tracker.Nixpkgs.Package

  @repo "NixOS/nixpkgs"
  @link_cap 1000
  @files_per_page 100
  @files_hard_cap 3000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"number" => number, "reason" => reason}}) do
    run(%{number: number, reason: reason})
  end

  @doc """
  Entry point for the refresh flow. Accepts `:attrdiff_fetcher` and
  `:rate_limit_table` options for test injection.
  """
  def run(args, opts \\ [])

  def run(%{reason: reason, number: number}, opts)
      when reason in ["merged", "head_sha_changed"] do
    Logger.info(msg: "artifact refresh started", number: number, reason: reason)
    started_at = System.monotonic_time()
    table = Keyword.get(opts, :rate_limit_table, RateLimitCache)

    {return_value, summary} =
      case RateLimitCache.check(:rest, table) do
        {:limited, seconds} ->
          Logger.info(msg: "REST rate limited, snoozing artifact refresh", seconds: seconds)
          {{:snooze, seconds}, %{outcome: :rate_limited, snooze_seconds: seconds}}

        :ok ->
          do_run(reason, number, opts)
      end

    log_finished(number, reason, summary, started_at)
    return_value
  end

  def run(%{reason: reason, number: number}, _opts) do
    Logger.info(msg: "artifact refresh started", number: number, reason: reason)

    Logger.warning(
      msg: "ChangeArtifactRefreshWorker: reason not yet implemented",
      number: number,
      reason: reason
    )

    Logger.info(
      msg: "artifact refresh finished",
      number: number,
      reason: reason,
      outcome: :unsupported_reason,
      duration_ms: 0
    )

    :ok
  end

  defp log_finished(number, reason, summary, started_at) do
    fields =
      [
        msg: "artifact refresh finished",
        number: number,
        reason: reason,
        duration_ms: duration_ms(started_at)
      ]
      |> Keyword.merge(Enum.to_list(summary))

    Logger.info(fields)
  end

  defp duration_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end

  defp do_run(reason, number, opts) do
    case Change.get_by_number(number) do
      {:ok, change} ->
        fetcher =
          Keyword.get_lazy(opts, :attrdiff_fetcher, fn -> default_fetcher_for(reason) end)

        case fetcher.(change) do
          {:ok, attrdiff} ->
            {status, package_count} = apply_refresh(change, attrdiff)
            changed_files = refresh_changed_files(change, opts)

            {:ok,
             %{
               outcome: :ok,
               status: status,
               package_count: package_count,
               changed_files: changed_files
             }}

          {:snooze, seconds} = snooze ->
            {snooze, %{outcome: :snoozed, snooze_seconds: seconds}}

          {:error, :rate_limited} ->
            snooze = snooze_seconds_for(:rest)
            Logger.warning(msg: "artifact refresh rate limited, snoozing", seconds: snooze)
            {{:snooze, snooze}, %{outcome: :rate_limited, snooze_seconds: snooze}}

          {:error, :no_workflow_run} when reason == "head_sha_changed" ->
            Logger.info(
              msg: "PR run not yet present, retrying artifact refresh",
              number: number
            )

            {{:error, :no_workflow_run}, %{outcome: :error, status: :no_workflow_run_retry}}

          {:error, terminal}
          when terminal in ~w(artifact_expired no_workflow_run no_comparison_artifact)a ->
            Logger.warning(
              msg: "terminal artifact refresh outcome",
              number: number,
              reason: terminal
            )

            Change.update_processing_status!(change, %{processing_status: terminal})
            {:ok, %{outcome: :ok, status: terminal}}

          {:error, reason} ->
            Logger.error(
              msg: "ChangeArtifactRefreshWorker fetch failed",
              number: number,
              reason: inspect(reason)
            )

            Change.update_processing_status!(change, %{processing_status: :failed})
            {{:error, reason}, %{outcome: :error, status: :failed, reason: inspect(reason)}}
        end

      _ ->
        Logger.warning(msg: "ChangeArtifactRefreshWorker: change not found", number: number)
        {:ok, %{outcome: :ok, status: :change_not_found}}
    end
  end

  defp default_fetcher_for("merged"), do: &default_merged_fetcher/1
  defp default_fetcher_for("head_sha_changed"), do: &default_head_sha_fetcher/1

  defp refresh_changed_files(change, opts) do
    case Keyword.get_lazy(opts, :files_fetcher, &configured_files_fetcher/0) do
      nil ->
        0

      fetcher ->
        case fetcher.(change) do
          {:ok, paths} when is_list(paths) ->
            replace_change_files!(change, paths)
            length(paths)

          {:error, reason} ->
            Logger.warning(
              msg: "changed_files fetch failed; package refresh kept",
              number: change.number,
              reason: inspect(reason)
            )

            0
        end
    end
  end

  defp replace_change_files!(change, paths) do
    normalized =
      paths
      |> Enum.map(&NixFile.normalize_path/1)
      |> Enum.uniq()

    Tracker.Repo.transaction(fn ->
      ChangeFile.clear_for_change!(change.id)

      case normalized do
        [] ->
          :ok

        paths ->
          file_id_map = NixFile.bulk_upsert_all(paths)

          records =
            Enum.map(paths, fn path ->
              %{change_id: change.id, file_id: Map.fetch!(file_id_map, path)}
            end)

          ChangeFile.bulk_insert_all(records)
      end
    end)

    :ok
  end

  defp configured_files_fetcher do
    Application.get_env(:tracker, :changed_files_fetcher, &default_files_fetcher/1)
  end

  defp default_files_fetcher(change) do
    [owner, repo] = String.split(@repo, "/")
    token = Tracker.GitHub.installation_token!()
    fetch_files_paginated(owner, repo, change.number, token, 1, [])
  end

  defp fetch_files_paginated(_owner, _repo, _number, _token, _page, acc)
       when length(acc) >= @files_hard_cap do
    Logger.warning(msg: "changed_files hit hard cap, truncating", cap: @files_hard_cap)
    {:ok, Enum.take(acc, @files_hard_cap)}
  end

  defp fetch_files_paginated(owner, repo, number, token, page, acc) do
    case GitHub.Pulls.list_files(owner, repo, number,
           per_page: @files_per_page,
           page: page,
           auth: token
         ) do
      {:ok, entries} when is_list(entries) ->
        names = Enum.map(entries, & &1.filename)
        next_acc = acc ++ names

        if length(entries) < @files_per_page do
          {:ok, next_acc}
        else
          fetch_files_paginated(owner, repo, number, token, page + 1, next_acc)
        end

      {:error, %GitHub.Error{reason: :rate_limited}} ->
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_refresh(change, attrdiff) do
    typed_entries =
      attrdiff
      |> flatten_attrdiff()
      |> Enum.uniq_by(&elem(&1, 1))

    total = length(typed_entries)

    status =
      cond do
        staging?(change) ->
          write_refresh!(change, [], :base_ref_skipped, total)
          :base_ref_skipped

        total > @link_cap ->
          Logger.warning(
            msg: "link cap exceeded, marking too_large",
            number: change.number,
            total: total,
            cap: @link_cap
          )

          write_refresh!(change, [], :too_large, total)
          :too_large

        true ->
          write_refresh!(change, build_link_records(change, typed_entries), :processed, total)
          :processed
      end

    {status, total}
  end

  # Staging-targeted PRs (base_ref starting with "staging") get
  # package_count from the attrdiff but no ChangePackage rows. Mass
  # staging churn would otherwise pollute per-package change lists.
  defp staging?(change),
    do: String.starts_with?(change.base_ref || "", "staging")

  defp build_link_records(change, typed_entries) do
    all_attrs = Enum.map(typed_entries, &elem(&1, 1))
    ensure_packages_exist(all_attrs)
    id_map = package_id_map(all_attrs)

    Enum.map(typed_entries, fn {type, attr} ->
      %{change_id: change.id, package_id: id_map[attr], type: type}
    end)
  end

  defp write_refresh!(change, records, status, total) do
    {:ok, notifications} =
      Tracker.Repo.transaction(fn ->
        ChangePackage.clear_for_change!(change.id)
        if records != [], do: ChangePackage.bulk_create_all(records)

        {_, n1} =
          Change.update_processing_status!(
            change,
            %{processing_status: status},
            return_notifications?: true
          )

        {_, n2} =
          Change.update_package_count!(
            change,
            %{package_count: total},
            return_notifications?: true
          )

        n1 ++ n2
      end)

    Ash.Notifier.notify(notifications)
  end

  @ignored_packages [
    "nixos-install-tools",
    "tests.nixos-functions.nixos-test"
  ]

  defp flatten_attrdiff(attrdiff) do
    Enum.flat_map(~w(added changed removed), fn type ->
      attrdiff[type]
      |> List.wrap()
      |> Enum.reject(&(&1 in @ignored_packages))
      |> Enum.map(&{String.to_existing_atom(type), &1})
    end)
  end

  defp ensure_packages_exist([]), do: :ok

  defp ensure_packages_exist(attrs) do
    attrs
    |> Enum.uniq()
    |> Enum.map(&%{attribute: &1})
    |> Package.bulk_upsert_all()

    :ok
  end

  defp package_id_map([]), do: %{}

  defp package_id_map(attrs) do
    attrs
    |> Package.ids_by_attributes!()
    |> Map.new(&{&1.attribute, &1.id})
  end

  defp default_merged_fetcher(change) do
    token = Tracker.GitHub.installation_token!()

    cache_first =
      case ChangeArtifactCache.fetch_comparison(change.number, expected_source: :merge_group) do
        {:ok, attrdiff} -> {:ok, attrdiff}
        {:error, _} -> :miss
      end

    case cache_first do
      {:ok, _} = ok ->
        ok

      :miss ->
        fetch_from_github(change,
          find_run: &find_merge_group_run/4,
          sha: change.merge_commit_sha,
          source: :merge_group,
          token: token
        )
    end
  end

  # Open/draft PRs: skip cache-first because head_sha (and thus the
  # underlying run) just changed. cache_run_artifacts overwrites the
  # cached comparison.zip when run_id differs, so the fetch path
  # always reflects the current head_sha.
  defp default_head_sha_fetcher(change) do
    token = Tracker.GitHub.installation_token!()

    fetch_from_github(change,
      find_run: &find_pr_run/4,
      sha: change.head_sha,
      source: :pr,
      token: token
    )
  end

  defp fetch_from_github(change, opts) do
    [owner, repo] = String.split(@repo, "/")
    find_run = Keyword.fetch!(opts, :find_run)
    sha = Keyword.fetch!(opts, :sha)
    source = Keyword.fetch!(opts, :source)
    token = Keyword.fetch!(opts, :token)

    with {:ok, run_id} <- find_run.(owner, repo, sha, token),
         {:ok, %{artifacts: artifacts}} <-
           GitHub.Actions.list_workflow_run_artifacts(owner, repo, run_id, auth: token),
         :ok <-
           ChangeArtifactCache.cache_run_artifacts(change.number, run_id, artifacts, token,
             source: source
           ),
         {:ok, attrdiff} <-
           ChangeArtifactCache.fetch_comparison(change.number, expected_source: source) do
      {:ok, attrdiff}
    else
      {:error, %GitHub.Error{reason: :rate_limited}} -> {:error, :rate_limited}
      other -> other
    end
  end

  defp find_merge_group_run(owner, repo, sha, token),
    do: find_run(owner, repo, sha, token, "Merge Group")

  defp find_pr_run(owner, repo, sha, token),
    do: find_run(owner, repo, sha, token, "PR")

  defp find_run(_owner, _repo, nil, _token, _name), do: {:error, :no_workflow_run}

  defp find_run(owner, repo, sha, token, name) do
    case GitHub.Actions.list_workflow_runs_for_repo(owner, repo,
           head_sha: sha,
           per_page: 100,
           auth: token
         ) do
      {:ok, %{workflow_runs: runs}} ->
        case Enum.find(runs, &(&1.name == name && &1.status == "completed")) do
          nil ->
            if Enum.find(runs, &(&1.name == name)) do
              Logger.info(
                msg: "workflow run not yet complete, snoozing",
                workflow: name,
                sha: sha
              )

              {:snooze, 120}
            else
              {:error, :no_workflow_run}
            end

          run ->
            {:ok, run.id}
        end

      {:error, %GitHub.Error{reason: :rate_limited}} ->
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp snooze_seconds_for(bucket) do
    token = Tracker.GitHub.installation_token!()
    Tracker.GitHub.seconds_until_reset(token, bucket)
  end
end
