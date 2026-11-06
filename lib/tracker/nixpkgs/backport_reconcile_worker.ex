defmodule Tracker.Nixpkgs.BackportReconcileWorker do
  use Oban.Worker,
    queue: :changes,
    max_attempts: 5,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias Tracker.GitHub.{GraphQL, RateLimitCache}
  alias Tracker.Nixpkgs.{BackportEvidence, BackportLink, Change, ChangeDiscoveryWorker}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case RateLimitCache.check(:graphql) do
      {:limited, seconds} ->
        {:snooze, seconds}

      :ok ->
        case run() do
          {:ok, _count} -> :ok
          {:error, _reason} = error -> error
        end
    end
  end

  def run(numbers \\ nil, opts \\ []) do
    numbers = numbers || next_numbers()
    fetcher = Keyword.get(opts, :fetcher, &GraphQL.fetch_numbers("NixOS/nixpkgs", &1, []))

    numbers
    |> Enum.uniq()
    |> Enum.chunk_every(25)
    |> Enum.reduce({0, nil}, fn batch, {count, error} ->
      case reconcile_batch(batch, fetcher, opts) do
        {:ok, processed} -> {count + processed, error}
        {:error, reason} -> {count, error || reason}
      end
    end)
    |> case do
      {count, nil} -> {:ok, count}
      {_count, error} -> {:error, error}
    end
  end

  defp next_numbers do
    historical = Enum.map(Change.backport_historical_backlog!(), & &1.number)
    priority_slots = 25 - length(historical)

    retries =
      Change.backport_retry_backlog!(%{exclude_numbers: historical, limit: priority_slots})
      |> Enum.map(& &1.number)

    remaining = priority_slots - length(retries)

    latest =
      if remaining > 0 do
        Change.backport_backlog!(%{exclude_numbers: historical ++ retries, limit: remaining})
        |> Enum.map(& &1.number)
      else
        []
      end

    retries ++ latest ++ historical
  end

  defp reconcile_batch(numbers, fetcher, opts) do
    snapshot = Change.by_numbers!(numbers)

    with {:ok, results} <- fetcher.(numbers),
         pulls = for({_number, {:pull_request, pr}} <- results, do: pr),
         {:ok, _count} <- ChangeDiscoveryWorker.upsert_pulls(pulls) do
      unavailable = numbers -- Enum.map(pulls, & &1.number)

      snapshot
      |> Enum.filter(&(&1.number in unavailable))
      |> Enum.each(&mark_checked(&1, DateTime.add(DateTime.utc_now(), 1, :day)))

      reconcile_results(pulls, numbers, fetcher, opts)
    else
      {:error, _reason} = error ->
        Enum.each(snapshot, &defer/1)
        error
    end
  end

  defp reconcile_results(pulls, numbers, fetcher, opts) do
    {changes, evidence_error} = reconcile_evidence(pulls, opts)

    import_error =
      case import_sources(changes, fetcher) do
        {:ok, retry?} ->
          retry_at = if retry?, do: DateTime.add(DateTime.utc_now(), 1, :day)
          Enum.each(changes, &mark_checked(&1, retry_at))
          nil

        {:error, reason} ->
          Enum.each(changes, &defer/1)
          reason
      end

    case evidence_error || import_error do
      nil -> {:ok, length(numbers)}
      reason -> {:error, reason}
    end
  end

  defp defer(%Change{} = change) do
    mark_checked(change, DateTime.add(DateTime.utc_now(), 5, :minute))
  end

  defp mark_checked(%Change{} = change, retry_at) do
    Change.mark_backport_checked!(change, %{
      backport_retry_at: retry_at,
      backport_gh_updated_at: change.gh_updated_at
    })
  end

  defp reconcile_evidence(pulls, opts) do
    commits_fetcher = Keyword.get(opts, :commits_fetcher, &GraphQL.fetch_pr_commit_messages/1)

    associations_fetcher =
      Keyword.get(opts, :associations_fetcher, &GraphQL.fetch_commit_pr_numbers/1)

    Enum.reduce(pulls, {[], nil}, fn pr, {changes, error} ->
      change = Change.get_by_number!(pr.number)

      with {:ok, messages} <- commits_fetcher.(pr.number),
           shas = BackportEvidence.source_commit_shas(messages),
           {:ok, associations} <- fetch_associations(shas, associations_fetcher) do
        sources = Enum.map(shas, &Map.fetch!(associations, &1))

        matches =
          change
          |> BackportEvidence.extract(sources)
          |> Enum.map(fn match ->
            commits =
              for sha <- shas,
                  match.source_number in Map.fetch!(associations, sha),
                  do: "source_commit: #{sha}"

            %{match | evidence: Enum.uniq(match.evidence ++ commits)}
          end)

        replace_links(change, matches)
        {[change | changes], error}
      else
        {:error, reason} ->
          defer(change)
          {changes, error || reason}
      end
    end)
  end

  defp fetch_associations([], _fetcher), do: {:ok, %{}}
  defp fetch_associations(shas, fetcher), do: fetcher.(shas)

  defp replace_links(%Change{} = change, matches) do
    {:ok, notifications} =
      Tracker.Repo.transaction(fn ->
        numbers = Enum.map(matches, & &1.source_number)
        existing = Map.new(BackportLink.for_backport!(change.id), &{&1.source_number, &1})

        removed =
          existing
          |> Map.values()
          |> Enum.reject(&(&1.source_number in numbers))
          |> Enum.flat_map(&BackportLink.destroy!(&1, return_notifications?: true))

        created =
          Enum.flat_map(matches, fn match ->
            prior = Map.get(existing, match.source_number)
            status = get_in(prior.source_status) || :pending

            {_link, notifications} =
              BackportLink.create!(
                %{
                  backport_id: change.id,
                  source_number: match.source_number,
                  confidence: if(status == :issue, do: :candidate, else: match.confidence),
                  evidence: match.evidence,
                  source_status: status
                },
                return_notifications?: true
              )

            notifications
          end)

        removed ++ created
      end)

    Ash.Notifier.notify(notifications)
    :ok
  end

  defp import_sources(changes, fetcher) do
    links = Enum.flat_map(changes, &BackportLink.for_backport!(&1.id))
    numbers = links |> Enum.map(& &1.source_number) |> Enum.uniq()
    existing = Change.by_numbers!(numbers) |> Map.new(&{&1.number, :imported})
    missing = numbers -- Map.keys(existing)

    with {:ok, statuses} <- fetch_sources(missing, existing, fetcher) do
      Enum.each(links, fn link ->
        BackportLink.resolve_source!(link, %{
          source_status: Map.fetch!(statuses, link.source_number)
        })
      end)

      {:ok, Enum.any?(statuses, fn {_number, status} -> status != :imported end)}
    else
      {:error, _reason} = error -> error
    end
  end

  defp fetch_sources(numbers, statuses, fetcher) do
    numbers
    |> Enum.chunk_every(25)
    |> Enum.reduce_while({:ok, statuses}, fn batch, {:ok, acc} ->
      with {:ok, results} <- fetcher.(batch),
           pulls = for({_number, {:pull_request, pr}} <- results, do: pr),
           {:ok, _count} <- ChangeDiscoveryWorker.upsert_pulls(pulls) do
        statuses =
          Map.new(results, fn
            {number, {:pull_request, _pr}} -> {number, :imported}
            {number, status} when status in [:issue, :not_found] -> {number, status}
          end)

        {:cont, {:ok, Map.merge(acc, statuses)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
