defmodule Tracker.PromEx.GitHub do
  @moduledoc false

  use PromEx.Plugin

  @impl PromEx.Plugin
  def event_metrics(_opts) do
    Event.build(:tracker_github_event_metrics, [
      last_value([:tracker, :github, :rate_limit, :limit],
        event_name: [:tracker, :github, :rate_limit],
        measurement: :limit,
        tags: [:resource],
        description: "Last observed GitHub quota limit."
      ),
      last_value([:tracker, :github, :rate_limit, :remaining],
        event_name: [:tracker, :github, :rate_limit],
        measurement: :remaining,
        tags: [:resource],
        description: "Last observed GitHub quota remaining; not refilled locally."
      ),
      last_value([:tracker, :github, :rate_limit, :reset_timestamp_seconds],
        event_name: [:tracker, :github, :rate_limit],
        measurement: :reset_timestamp_seconds,
        tags: [:resource],
        description: "Last observed GitHub quota reset Unix timestamp in seconds."
      ),
      last_value([:tracker, :github, :rate_limit, :observed_timestamp_seconds],
        event_name: [:tracker, :github, :rate_limit],
        measurement: :observed_timestamp_seconds,
        tags: [:resource],
        description: "Unix timestamp in seconds of the last GitHub quota observation."
      ),
      counter([:tracker, :github, :rate_limited, :total],
        event_name: [:tracker, :github, :rate_limited],
        tags: [:resource],
        description: "GitHub responses reporting a rate limit."
      ),
      sum([:tracker, :github, :graphql, :cost, :total],
        event_name: [:tracker, :github, :graphql, :cost],
        measurement: :cost,
        tags: [:resource],
        description: "Total observed GitHub GraphQL query cost."
      )
    ])
  end
end
