defmodule TrackerWeb.ChannelLive.DiffSections do
  use TrackerWeb, :html

  alias Tracker.Nixpkgs.ChannelRevision
  alias Tracker.Nixpkgs.RevisionComparison.Page
  alias TrackerWeb.Pagination

  attr :channel, :string, required: true
  attr :revision, ChannelRevision, required: true
  attr :previous_revision, ChannelRevision, default: nil
  attr :formatted_released_at, :string, required: true
  attr :lens_path, :string, required: true
  attr :from_path, :string, default: nil
  attr :to_path, :string, required: true
  attr :package_page, Page, required: true
  attr :option_page, Page, required: true
  attr :change, :string, default: "all"
  attr :filter_paths, :map, required: true
  attr :package_prev_path, :string, required: true
  attr :package_next_path, :string, required: true
  attr :option_prev_path, :string, required: true
  attr :option_next_path, :string, required: true

  def revision_comparison(assigns) do
    ~H"""
    <div class="revision-comparison">
      <header class="comparison-header">
        <h1 class="opt-pathbar">
          <.link navigate={~p"/channels/#{@channel}"} class="crumb-link">{@channel}</.link>
          <span class="crumb-sep" aria-hidden="true">/</span>
          <span class="crumb-current" title={@revision.revision}>
            {String.slice(@revision.revision, 0, 7)}
          </span>
        </h1>
        <p class="comparison-released">Released {@formatted_released_at}</p>
        <.link :if={@lens_path} navigate={@lens_path} class="outline comparison-lens" role="button">Use as lens</.link>
      </header>

      <div :if={@previous_revision} class="comparison-endpoints">
        <.comparison_endpoint label="From Revision" revision={@previous_revision} path={@from_path} />
        <.comparison_endpoint label="To Revision" revision={@revision} path={@to_path} />
        <div class="comparison-compare">
          <a
            href={"https://github.com/NixOS/nixpkgs/compare/#{@previous_revision.revision}...#{@revision.revision}"}
            target="_blank"
            rel="noopener noreferrer"
            class="outline"
            role="button"
          >
            Compare <span aria-hidden="true">↗</span><span class="sr-only"> on GitHub</span>
          </a>
        </div>
      </div>
      <div :if={is_nil(@previous_revision)} class="comparison-baseline">
        <p>This is the first known revision in this channel. There is no predecessor to compare.</p>
        <a
          href={"https://github.com/NixOS/nixpkgs/commit/#{@revision.revision}"}
          target="_blank"
          rel="noopener noreferrer"
          class="outline"
          role="button"
        >View on GitHub <span aria-hidden="true">↗</span></a>
      </div>

      <section :if={@previous_revision} id="packages" aria-labelledby="package-changes-title">
        <div class="comparison-section-heading">
          <h2 id="package-changes-title">Package changes</h2>
          <span>{comparison_total(@package_page.counts)} packages</span>
        </div>
        <div class="comparison-package-panel">
          <.comparison_filters
            counts={@package_page.counts}
            change={@change}
            paths={@filter_paths}
            changed_label="Version changed"
          />
          <table class="comparison-packages">
            <thead>
              <tr>
                <th scope="col">Package</th><th scope="col">Change</th><th scope="col">
                  From version
                </th><th scope="col">To version</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @package_page.results}>
                <td class="comparison-package-name">
                  <.link navigate={~p"/packages/#{row.attribute}"}>{row.attribute}</.link>
                </td>
                <td class="comparison-package-change">
                  <.comparison_badge type={row.type} changed_label="Version changed" />
                </td>
                <td class="comparison-version comparison-version-from">{row.old_version || "—"}</td>
                <td class="comparison-version comparison-version-to">
                  <span class="comparison-version-arrow" aria-hidden="true">→</span>{row.new_version ||
                    "—"}
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@package_page.results == []} class="comparison-empty">
            No package changes match this comparison.
          </p>
        </div>
        <div aria-label="Package pagination">
          <Pagination.controls
            total_pages={@package_page.total_pages}
            current_page={@package_page.page}
            has_prev_page?={@package_page.page > 1}
            has_next_page?={@package_page.page < @package_page.total_pages}
            prev_path={@package_prev_path}
            next_path={@package_next_path}
            anchor="packages"
          />
        </div>
      </section>

      <section :if={@previous_revision} id="options" aria-labelledby="option-changes-title">
        <div class="comparison-section-heading">
          <h2 id="option-changes-title">Option changes</h2>
          <span>{comparison_total(@option_page.counts)} options</span>
        </div>
        <div class="comparison-options">
          <article :for={row <- @option_page.results} class="comparison-option">
            <header class="comparison-option-header">
              <.link navigate={~p"/options/#{row.name}"}>{row.name}</.link>
              <.comparison_badge type={row.type} changed_label="Metadata changed" />
            </header>
            <p :if={row.fields == []} class="comparison-empty">
              {if row.type == :added, do: "This option was added.", else: "This option was removed."}
            </p>
            <div :for={field <- row.fields} class="comparison-field">
              <p class="comparison-field-label">Changed field <strong>{field.field}</strong></p>
              <div class="comparison-values">
                <div>
                  <span class="comparison-value-label">From</span><p>
                    {metadata_excerpt(field.old, field.new)}
                  </p>
                </div>
                <div>
                  <span class="comparison-value-label">To</span><p>
                    {metadata_excerpt(field.new, field.old)}
                  </p>
                </div>
              </div>
              <details>
                <summary>View full {field.field} before and after</summary>
                <div class="comparison-values comparison-full-values">
                  <div>
                    <span class="comparison-value-label">From</span><pre>{format_metadata_value(field.old)}</pre>
                  </div>
                  <div>
                    <span class="comparison-value-label">To</span><pre>{format_metadata_value(field.new)}</pre>
                  </div>
                </div>
              </details>
            </div>
          </article>
          <p :if={@option_page.results == []} class="comparison-empty">
            No option changes match this comparison.
          </p>
          <p class="comparison-option-counts">
            {@option_page.count} matching options · {@option_page.counts.added} added · {@option_page.counts.removed} removed · {@option_page.counts.changed} metadata changed
          </p>
        </div>
        <div aria-label="Option pagination">
          <Pagination.controls
            total_pages={@option_page.total_pages}
            current_page={@option_page.page}
            has_prev_page?={@option_page.page > 1}
            has_next_page?={@option_page.page < @option_page.total_pages}
            prev_path={@option_prev_path}
            next_path={@option_next_path}
            anchor="options"
          />
        </div>
      </section>
      <p class="comparison-footnote">Revision comparison on {@channel}.</p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :revision, ChannelRevision, required: true
  attr :path, :string, required: true

  defp comparison_endpoint(assigns) do
    ~H"""
    <div class="comparison-endpoint">
      <div>
        <span class="comparison-value-label">{@label}</span>
        <.link navigate={@path} title={@revision.revision}>{String.slice(@revision.revision, 0, 7)}</.link>
      </div>
      <a
        href={"https://github.com/NixOS/nixpkgs/commit/#{@revision.revision}"}
        target="_blank"
        rel="noopener noreferrer"
        class="outline"
        role="button"
        aria-label={"#{@label} on GitHub"}
      >
        GitHub <span aria-hidden="true">↗</span>
      </a>
    </div>
    """
  end

  attr :counts, :any, required: true
  attr :change, :string, required: true
  attr :changed_label, :string, required: true
  attr :paths, :map, required: true

  defp comparison_filters(assigns) do
    ~H"""
    <div class="comparison-filters" role="group" aria-label="Filter changes">
      <.link
        :for={
          {value, label, count} <- [
            {"all", "All", comparison_total(@counts)},
            {"changed", @changed_label, @counts.changed},
            {"added", "Added", @counts.added},
            {"removed", "Removed", @counts.removed}
          ]
        }
        patch={@paths[value]}
        role="button"
        data-change={value}
        aria-pressed={to_string(@change == value)}
      >
        {label} <span>{count}</span>
      </.link>
    </div>
    """
  end

  attr :type, :atom, required: true
  attr :changed_label, :string, required: true

  defp comparison_badge(assigns) do
    ~H"""
    <span class={["comparison-badge", "comparison-badge--#{@type}"]}>
      {case @type do
        :added -> "Added"
        :removed -> "Removed"
        :changed -> @changed_label
      end}
    </span>
    """
  end

  defp comparison_total(counts), do: counts.added + counts.removed + counts.changed

  defp metadata_excerpt(value, counterpart) do
    text = format_metadata_value(value)
    common_bytes = :binary.longest_common_prefix([text, format_metadata_value(counterpart)])
    start = max(String.length(binary_part(text, 0, common_bytes)) - 80, 0)
    excerpt = String.slice(text, start, 240)
    leading = if start > 0, do: "…", else: ""
    trailing = if start + 240 < String.length(text), do: "…", else: ""
    leading <> excerpt <> trailing
  end

  defp format_metadata_value(nil), do: "—"
  defp format_metadata_value(true), do: "true"
  defp format_metadata_value(false), do: "false"
  defp format_metadata_value(value) when is_binary(value), do: value
  defp format_metadata_value(value), do: inspect(value)
end
