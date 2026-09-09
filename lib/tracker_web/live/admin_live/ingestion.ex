defmodule TrackerWeb.AdminLive.Ingestion do
  use TrackerWeb, :live_view

  alias Tracker.Ingestion.{Pipeline, PipelineStarter}
  alias TrackerWeb.RowList
  alias TrackerWeb.Time
  alias TrackerWeb.SectionHeader

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Ingestion")
     |> load_pipelines()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.header>
      Ingestion
      <:subtitle>
        A wedged chain head blocks every revision behind it. Fix the cause, then retry.
      </:subtitle>
      <:actions>
        <.link href={~p"/admin/ash"}>Resource admin</.link>
      </:actions>
    </.header>

    <SectionHeader.section_header title="Needs attention" count={length(@pipelines)} />

    <p :if={@pipelines == []}>No unhealthy pipelines.</p>

    <div class="pipeline-list">
      <RowList.row_list :if={@pipelines != []} id="unhealthy-pipelines" stacked>
        <RowList.row :for={p <- @pipelines} id={"pipeline-#{p.id}"} mode={:expandable}>
          <:label>
            {p.channel.name} <code>{short_revision(p.revision)}</code>
          </:label>
          <:sublabel>
            <span>{p.status} at {p.failed_step}</span>
            <span>released {format_datetime(p.released_at, @time_zone)}</span>
            <span>retries {p.retry_count}/{Pipeline.max_auto_retries()}</span>
            <span data-blocked-count={p.channel.pending_pipeline_count}>
              {p.channel.pending_pipeline_count} blocked behind it
            </span>
            <a href={oban_jobs_path(p)}>Oban jobs</a>
          </:sublabel>
          <:body>
            <pre class="pipeline-error">{p.error}</pre>
          </:body>
          <:actions>
            <button
              type="button"
              phx-click="retry"
              phx-value-id={p.id}
              data-confirm="Retry this pipeline from its failed step?"
            >
              Retry
            </button>
          </:actions>
        </RowList.row>
      </RowList.row_list>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("retry", %{"id" => id}, socket) do
    pipeline = Pipeline.get_pipeline!(String.to_integer(id))

    socket =
      if pipeline.status in [:failed, :stuck] do
        PipelineStarter.retry_pipeline(pipeline)
        put_flash(socket, :info, "Retrying pipeline #{pipeline.id} from #{pipeline.failed_step}.")
      else
        put_flash(
          socket,
          :error,
          "Pipeline #{pipeline.id} could not be retried — it is now #{pipeline.status}."
        )
      end

    {:noreply, load_pipelines(socket)}
  end

  defp load_pipelines(socket), do: assign(socket, :pipelines, Pipeline.unhealthy!())

  defp short_revision(revision), do: String.slice(revision, 0, 7)

  # Oban Web splits an `args` filter into path and term on a literal `++`, which
  # has to survive query decoding as `%2B%2B` or it arrives as a space and the
  # filter is silently dropped. `discarded` is the only state these jobs can be
  # in: `StepWorker` marks a pipeline failed or stuck only once Oban has spent
  # every attempt, at which point the job is discarded.
  defp oban_jobs_path(pipeline) do
    "/dev/oban/jobs?args=pipeline_id%2B%2B#{pipeline.id}&state=discarded"
  end

  defp format_datetime(nil, _time_zone), do: "—"
  defp format_datetime(dt, time_zone), do: Time.format_datetime(dt, time_zone)
end
