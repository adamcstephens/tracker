# Resets span ingestion state on an existing deployment so channel data can be
# re-ingested from scratch under the span model (trk-318). Truncates the
# ingestion ledger (ingestion_pipelines, ingestion_runs) and the three span
# tables. Leaves identity tables (channels, channel_revisions, packages,
# options, files) and all user data (subscriptions, notifications, changes)
# untouched — identity rows are upserted by natural key on re-ingest, so
# existing IDs and the user-data FKs pointing at them stay valid.
#
# Run the spans_target_schema migration first. Without confirmation this is a
# dry run that only prints row counts.
#
#   dev:  mix run scripts/spans_prod_cleanup.exs --yes
#   prod: bin/tracker rpc 'System.put_env("CLEANUP_CONFIRM", "yes"); Code.eval_file("scripts/spans_prod_cleanup.exs")'
#
# (Under `rpc` this runs on the live node; copy the script to the release host
# if scripts/ is not shipped with the release.)

alias Tracker.Repo

tables = ~w(ingestion_pipelines ingestion_runs package_spans option_spans option_file_spans)
span_tables = ~w(package_spans option_spans option_file_spans)

%{rows: [[present]]} =
  Repo.query!(
    "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = ANY($1)",
    [span_tables]
  )

if present != length(span_tables) do
  raise "span tables missing — run the spans_target_schema migration before cleanup"
end

IO.puts("Will TRUNCATE ... RESTART IDENTITY:")

for table <- tables do
  %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table}")
  IO.puts("  #{table}: #{count} rows")
end

confirmed? = System.get_env("CLEANUP_CONFIRM") == "yes" or "--yes" in System.argv()

if confirmed? do
  :ok = Oban.pause_queue(queue: :ingestion)
  {:ok, cancelled} = Oban.cancel_all_jobs(Oban.Job.query(queue: :ingestion))
  IO.puts("Paused :ingestion queue, cancelled #{cancelled} pending/executing jobs")

  # cancellation of executing jobs is signalled asynchronously; let in-flight
  # writes drain before truncating the tables they touch
  Process.sleep(2_000)

  Repo.query!("TRUNCATE #{Enum.join(tables, ", ")} RESTART IDENTITY")
  IO.puts("Truncated #{Enum.join(tables, ", ")}")

  :ok = Oban.resume_queue(queue: :ingestion)

  IO.puts("""

  Done. The :ingestion queue is resumed — cron sync is a no-op until a
  bootstrap backfill creates the first completed pipeline. Kick off
  re-ingestion per channel:

      Tracker.Nixpkgs.SpanBackfill.run("nixos-unstable", ~U[2020-03-27 00:00:00Z])
  """)
else
  IO.puts("""

  Dry run only — nothing changed.
  Pass --yes (mix run) or set CLEANUP_CONFIRM=yes (rpc) to execute.
  """)
end
