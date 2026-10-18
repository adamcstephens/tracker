defmodule Tracker.PromEx.Oban do
  @moduledoc false

  use PromEx.Plugin

  @job_events [[:oban, :job, :stop], [:oban, :job, :exception]]
  @finished_event [:tracker, :oban, :job, :finished]
  @buckets [0.01, 0.1, 0.5, 1, 5, 15, 30, 60, 120, 300, 600, 1_800, 3_600]

  @impl PromEx.Plugin
  def event_metrics(_opts) do
    # Reporters do not merge same-name metrics attached to different events.
    # Normalize both terminal events once so every attempt shares one family.
    case :telemetry.attach_many(
           {__MODULE__, :job_events},
           @job_events,
           &__MODULE__.handle_job_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end

    Event.build(:tracker_oban_job_event_metrics, [
      counter([:tracker, :oban, :job, :attempts, :total],
        event_name: @finished_event,
        description: "Oban job attempts by execution outcome",
        tags: [:queue, :worker, :state],
        tag_values: &job_tags/1
      ),
      distribution([:tracker, :oban, :job, :duration, :seconds],
        event_name: @finished_event,
        measurement: :duration,
        description: "Oban job execution duration in seconds",
        tags: [:queue, :worker],
        tag_values: &job_tags/1,
        unit: {:native, :second},
        reporter_options: [buckets: @buckets]
      ),
      distribution([:tracker, :oban, :job, :queue, :time, :seconds],
        event_name: @finished_event,
        measurement: :queue_time,
        description: "Time Oban jobs waited in the queue in seconds",
        tags: [:queue, :worker],
        tag_values: &job_tags/1,
        unit: {:native, :second},
        reporter_options: [buckets: @buckets]
      )
    ])
  end

  @doc false
  def handle_job_event(
        _event,
        measurements,
        %{conf: %Oban.Config{name: Oban}} = metadata,
        _config
      ) do
    :telemetry.execute(@finished_event, measurements, metadata)
  end

  def handle_job_event(_event, _measurements, _metadata, _config), do: :ok

  defp job_tags(%{job: %Oban.Job{} = job, state: state}) do
    %{queue: job.queue, worker: job.worker, state: state}
  end
end
