defmodule TrackerWeb.ChangeLive.Show do
  use TrackerWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      <a href={@change.url} target="_blank" rel="noopener noreferrer">
        #{@change.number}
      </a>
      {@change.title}
    </.header>

    <.list>
      <:item title="State">
        <mark :if={@change.state == :merged}>merged</mark>
        <span :if={@change.state == :open}>open</span>
        <span :if={@change.state == :closed}>closed</span>
      </:item>
      <:item title="Author">
        {author_display(@change, @author_maintainer)}
      </:item>
      <:item :if={@merger_maintainer} title="Merged by">
        <.link navigate={~p"/maintainers/#{@merger_maintainer.github}"}>
          {@merger_maintainer.name || @merger_maintainer.github}
        </.link>
      </:item>
      <:item title="Base branch">{@change.base_ref}</:item>
      <:item :if={@change.merged_at} title="Merged at">
        {format_datetime(@change.merged_at)}
      </:item>
      <:item :if={@change.gh_created_at} title="Created at">
        {format_datetime(@change.gh_created_at)}
      </:item>
      <:item :if={@change.merge_commit_sha} title="Merge commit">
        <a
          href={"https://github.com/NixOS/nixpkgs/commit/#{@change.merge_commit_sha}"}
          target="_blank"
          rel="noopener noreferrer"
        >
          {String.slice(@change.merge_commit_sha, 0, 12)}
        </a>
      </:item>
    </.list>

    <div :if={@change.labels && @change.labels != []} style="margin-top: 1rem;">
      <strong>Labels</strong>
      <div style="display: flex; flex-wrap: wrap; gap: 0.25rem; margin-top: 0.25rem;">
        <kbd :for={label <- @change.labels} style="font-size: 0.75rem;">
          {label}
        </kbd>
      </div>
    </div>

    <section :if={@change.packages != []}>
      <h2>Affected Packages</h2>
      <ul>
        <li :for={pkg <- @change.packages}>
          <.link navigate={~p"/packages/#{pkg.attribute}"}>{pkg.attribute}</.link>
          <small :if={pkg.description}> -  {pkg.description}</small>
        </li>
      </ul>
    </section>

    <.back navigate={~p"/changes"}>Back to changes</.back>
    """
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp author_display(change, nil), do: change.author || "Unknown"

  defp author_display(_change, maintainer) do
    assigns = %{maintainer: maintainer}

    ~H"""
    <.link navigate={~p"/maintainers/#{@maintainer.github}"}>
      {@maintainer.name || @maintainer.github}
    </.link>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"number" => number_str}, _url, socket) do
    number = String.to_integer(number_str)
    change = Tracker.Nixpkgs.Change.get_by_number!(number, load: [:packages])

    author_maintainer = find_maintainer(change.author_github_id)
    merger_maintainer = find_maintainer(change.merged_by_github_id)

    {:noreply,
     socket
     |> assign(:page_title, "##{change.number} #{change.title}")
     |> assign(:change, change)
     |> assign(:author_maintainer, author_maintainer)
     |> assign(:merger_maintainer, merger_maintainer)}
  end

  defp find_maintainer(nil), do: nil

  defp find_maintainer(github_id) do
    case Tracker.Nixpkgs.Maintainer.get_by_github_id(github_id) do
      {:ok, maintainer} -> maintainer
      _ -> nil
    end
  end
end
