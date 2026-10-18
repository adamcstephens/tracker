defmodule Tracker.PromEx.ObanTest do
  use ExUnit.Case, async: false

  alias Tracker.PromEx.Oban, as: ObanMetrics

  defmodule Worker do
    use Oban.Worker, queue: :metrics

    @impl Oban.Worker
    def perform(%Oban.Job{} = job) do
      case job.args["outcome"] do
        "success" -> :ok
        "failure" -> {:error, :failed}
        "cancelled" -> {:cancel, :cancelled}
        "discard" -> :discard
        "snoozed" -> {:snooze, 60}
      end
    end
  end

  @reporter Module.concat(__MODULE__, Reporter)

  setup do
    groups = ObanMetrics.event_metrics(otp_app: :tracker)
    metrics = groups |> List.wrap() |> Enum.flat_map(& &1.metrics)
    adapter = PromEx.storage_adapter()
    start_supervised!(adapter.child_spec(@reporter, metrics))

    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:oban, :job, :stop], [:oban, :job, :exception]],
        &__MODULE__.capture_job_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{adapter: adapter}
  end

  test "counts actual execution outcomes without treating snoozes and cancellations as success",
       %{
         adapter: adapter
       } do
    for outcome <- ["success", "failure", "cancelled", "discard", "snoozed"] do
      execute(outcome)
    end

    execute("failure", attempt: 1, max_attempts: 1)
    scrape = adapter.scrape(@reporter)

    for {state, count} <- [
          {"success", 1},
          {"failure", 1},
          {"cancelled", 1},
          {"discard", 2},
          {"snoozed", 1}
        ] do
      assert samples(scrape, "tracker_oban_job_attempts_total", state: state) == [count]
    end
  end

  test "aggregates stop and exception timings into shared second-based histograms", %{
    adapter: adapter
  } do
    execute("success")
    execute("failure")

    assert_receive {:job_event, [:oban, :job, :stop], success_measurements}
    assert_receive {:job_event, [:oban, :job, :exception], failure_measurements}

    expected_duration =
      (success_measurements.duration + failure_measurements.duration) /
        System.convert_time_unit(1, :second, :native)

    scrape = adapter.scrape(@reporter)

    assert samples(scrape, "tracker_oban_job_duration_seconds_count") == [2]
    assert [duration] = samples(scrape, "tracker_oban_job_duration_seconds_sum")
    assert_in_delta duration, expected_duration, 0.000001

    assert samples(scrape, "tracker_oban_job_queue_time_seconds_count") == [2]
    assert [queue_time] = samples(scrape, "tracker_oban_job_queue_time_seconds_sum")
    assert_in_delta queue_time, 5.0, 0.000001

    assert length(Regex.scan(~r/^# TYPE tracker_oban_job_duration_seconds histogram$/m, scrape)) ==
             1

    assert length(Regex.scan(~r/^# TYPE tracker_oban_job_queue_time_seconds histogram$/m, scrape)) ==
             1
  end

  test "ignores other Oban instances and does not duplicate metrics after reinitialization", %{
    adapter: adapter
  } do
    ObanMetrics.event_metrics(otp_app: :tracker)
    execute("success")
    execute("success", name: __MODULE__)

    scrape = adapter.scrape(@reporter)
    assert samples(scrape, "tracker_oban_job_attempts_total", state: "success") == [1]
    assert samples(scrape, "tracker_oban_job_duration_seconds_count") == [1]
    assert samples(scrape, "tracker_oban_job_queue_time_seconds_count") == [1]
  end

  def capture_job_event(event, measurements, %{job: %Oban.Job{} = job}, pid) do
    if job.worker == inspect(Worker) do
      send(pid, {:job_event, event, measurements})
    end
  end

  defp execute(outcome, opts \\ []) do
    {conf_opts, job_opts} = Keyword.split(opts, [:name])
    attempted_at = ~U[2026-10-18 12:00:02.500000Z]
    scheduled_at = ~U[2026-10-18 12:00:00.000000Z]

    job =
      Oban.Testing.build_job(
        Worker,
        %{outcome: outcome},
        Keyword.merge([attempted_at: attempted_at, scheduled_at: scheduled_at], job_opts)
      )

    Oban.Testing.perform_job(job, Keyword.put(conf_opts, :repo, Tracker.Repo))
  end

  defp samples(scrape, metric, labels \\ []) do
    labels = [queue: "metrics", worker: inspect(Worker)] ++ labels

    scrape
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^#{Regex.escape(metric)}\{([^}]*)\} ([^ ]+)$/, line) do
        [_, actual_labels, value] ->
          if Enum.all?(labels, fn {key, expected} ->
               String.contains?(actual_labels, "#{key}=\"#{expected}\"")
             end) do
            [value |> Float.parse() |> elem(0)]
          else
            []
          end

        _ ->
          []
      end
    end)
  end
end
