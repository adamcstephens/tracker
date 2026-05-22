defmodule TrackerWeb.ChannelLive.DiffSections do
  use TrackerWeb, :html

  alias Tracker.Nixpkgs.ChannelRevision.RevisionDiff

  attr :diff, RevisionDiff, required: true

  def revision_diff_summary(assigns) do
    counts = diff_counts(assigns.diff)
    assigns = assign(assigns, :counts, counts)

    ~H"""
    <dl class="diff-summary">
      <div>
        <dt>Packages:</dt>
        <dd>
          {@counts.packages_added} added &middot; {@counts.packages_removed} removed &middot; {pluralize(
            @counts.version_changes,
            "version change",
            "version changes"
          )}
        </dd>
      </div>
      <div>
        <dt>Options:</dt>
        <dd>
          {@counts.options_added} added &middot; {@counts.options_removed} removed &middot; {pluralize(
            @counts.option_metadata_changes,
            "metadata change",
            "metadata changes"
          )}
        </dd>
      </div>
    </dl>
    """
  end

  defp diff_counts(%RevisionDiff{} = diff) do
    %{
      packages_added: Enum.count(diff.package_events, &(&1.type == :added)),
      packages_removed: Enum.count(diff.package_events, &(&1.type == :removed)),
      version_changes:
        Enum.count(diff.version_changes, &(&1.old_version != nil and &1.new_version != nil)),
      options_added: Enum.count(diff.option_events, &(&1.type == :added)),
      options_removed: Enum.count(diff.option_events, &(&1.type == :removed)),
      option_metadata_changes: length(diff.option_metadata_changes)
    }
  end

  defp pluralize(1, singular, _plural), do: "1 #{singular}"
  defp pluralize(n, _singular, plural), do: "#{n} #{plural}"

  defp diff_empty?(%RevisionDiff{} = diff) do
    diff.package_events == [] and diff.version_changes == [] and
      diff.option_events == [] and diff.option_metadata_changes == []
  end

  attr :diff, RevisionDiff, required: true
  attr :channel, :string, required: true
  attr :heading_level, :atom, default: :h3, values: [:h3, :h4]
  attr :show_revision_column, :boolean, default: false
  attr :empty_message, :string, required: true

  def revision_diff_sections(assigns) do
    ~H"""
    <.revision_diff_summary :if={not diff_empty?(@diff)} diff={@diff} />

    <section :if={@diff.package_events != []}>
      <.section_heading level={@heading_level}>Package Events</.section_heading>
      <figure>
        <table role="grid">
          <thead>
            <tr>
              <th>Package</th>
              <th>Event</th>
              <th :if={@show_revision_column}>Revision</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={event <- @diff.package_events}>
              <td>
                <a href={~p"/packages/#{event.package.attribute}"}>{event.package.attribute}</a>
              </td>
              <td>{format_event_type(event.type)}</td>
              <td :if={@show_revision_column}>
                <.revision_link revision={event.channel_revision.revision} channel={@channel} />
              </td>
            </tr>
          </tbody>
        </table>
      </figure>
    </section>

    <section :if={@diff.version_changes != []}>
      <.section_heading level={@heading_level}>Version Changes</.section_heading>
      <figure>
        <table role="grid">
          <thead>
            <tr>
              <th>Package</th>
              <th>Old Version</th>
              <th>New Version</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={change <- @diff.version_changes}>
              <td>
                <a href={~p"/packages/#{change.attribute}"}>{change.attribute}</a>
              </td>
              <td>{change.old_version || "—"}</td>
              <td>{change.new_version || "—"}</td>
            </tr>
          </tbody>
        </table>
      </figure>
    </section>

    <section :if={@diff.option_events != []}>
      <.section_heading level={@heading_level}>Option Events</.section_heading>
      <figure>
        <table role="grid">
          <thead>
            <tr>
              <th>Option</th>
              <th>Event</th>
              <th :if={@show_revision_column}>Revision</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={event <- @diff.option_events}>
              <td>
                <a href={~p"/options/#{event.option.name}"}>{event.option.name}</a>
              </td>
              <td>{format_event_type(event.type)}</td>
              <td :if={@show_revision_column}>
                <.revision_link revision={event.channel_revision.revision} channel={@channel} />
              </td>
            </tr>
          </tbody>
        </table>
      </figure>
    </section>

    <section :if={@diff.option_metadata_changes != []}>
      <.section_heading level={@heading_level}>Option Metadata Changes</.section_heading>
      <figure>
        <table role="grid">
          <thead>
            <tr>
              <th>Option</th>
              <th>Field</th>
              <th>Old</th>
              <th>New</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={change <- @diff.option_metadata_changes}>
              <td>
                <a href={~p"/options/#{change.option_name}"}>{change.option_name}</a>
              </td>
              <td>{change.field}</td>
              <td>{format_metadata_value(change.old)}</td>
              <td>{format_metadata_value(change.new)}</td>
            </tr>
          </tbody>
        </table>
      </figure>
    </section>

    <p :if={
      @diff.package_events == [] and @diff.version_changes == [] and
        @diff.option_events == [] and @diff.option_metadata_changes == []
    }>
      {@empty_message}
    </p>
    """
  end

  attr :level, :atom, required: true
  slot :inner_block, required: true

  defp section_heading(%{level: :h3} = assigns) do
    ~H"<h3>{render_slot(@inner_block)}</h3>"
  end

  defp section_heading(%{level: :h4} = assigns) do
    ~H"<h4>{render_slot(@inner_block)}</h4>"
  end

  attr :revision, :string, required: true
  attr :channel, :string, required: true

  defp revision_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/channels/#{@channel}/revisions/#{@revision}"}
      title={@revision}
      class="revision-link"
    >
      {String.slice(@revision, 0, 7)}
    </.link>
    """
  end

  defp format_event_type(:added), do: "added"
  defp format_event_type(:removed), do: "removed"

  defp format_metadata_value(nil), do: "—"
  defp format_metadata_value(true), do: "true"
  defp format_metadata_value(false), do: "false"
  defp format_metadata_value(value) when is_binary(value), do: value
  defp format_metadata_value(value), do: inspect(value)
end
