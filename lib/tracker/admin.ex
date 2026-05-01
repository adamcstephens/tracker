defmodule Tracker.Admin do
  @moduledoc """
  One-shot operational helpers, intended for invocation from a console
  (or `mcp__tidewave__project_eval`). Not part of any request flow.
  """

  alias Tracker.Nixpkgs.Change
  alias Tracker.Nixpkgs.ChangeArtifactRefreshWorker

  def reprocess_change(number, reason \\ "head_sha_changed")
      when is_integer(number) and reason in ["head_sha_changed", "merged"] do
    Tracker.Nixpkgs.ChangeArtifactRefreshWorker.run(%{reason: reason, number: number})
  end

  @doc """
  Re-enqueues `ChangeArtifactRefreshWorker` for every Change that GitHub
  has touched within the given window, routing each by state:

    * `:open` / `:draft` → reason `"head_sha_changed"`
    * `:merged` → reason `"merged"` (cache-first usually short-circuits
      the GitHub call)

  Closed-not-merged Changes are never enqueued — they have no artifact
  path — and are filtered out even if `:states` includes `:closed`.

  The worker's 5-minute Oban unique constraint dedupes accidental
  re-enqueues. Returns `{:ok, %{"head_sha_changed" => n, "merged" => m}}`.

  Options:
    * `:window_days` — how far back to look (default `7`)
    * `:states` — which Change states to consider (default
      `[:open, :draft, :merged]`)
  """
  @spec reprocess_recent_changes(keyword()) ::
          {:ok, %{String.t() => non_neg_integer()}}
  def reprocess_recent_changes(opts \\ []) do
    window_days = Keyword.get(opts, :window_days, 7)
    states = Keyword.get(opts, :states, [:open, :draft, :merged])
    since = DateTime.add(DateTime.utc_now(), -window_days * 86_400, :second)

    changes = Change.updated_since!(since, states)

    {jobs, counts} =
      Enum.reduce(changes, {[], %{"head_sha_changed" => 0, "merged" => 0}}, fn c,
                                                                               {jobs, counts} ->
        reason = reason_for(c.state)

        job =
          ChangeArtifactRefreshWorker.new(%{"number" => c.number, "reason" => reason})

        {[job | jobs], Map.update!(counts, reason, &(&1 + 1))}
      end)

    Oban.insert_all(jobs)
    {:ok, counts}
  end

  defp reason_for(state) when state in [:open, :draft], do: "head_sha_changed"
  defp reason_for(:merged), do: "merged"
end
