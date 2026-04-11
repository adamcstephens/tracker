defmodule TrackerWeb.DataTable do
  @moduledoc """
  Interactive table component with sortable columns and built-in pagination.

  Emits `sort`, `prev-page`, and `next-page` events for the parent LiveView to handle.
  """
  use Phoenix.Component
  use Gettext, backend: TrackerWeb.Gettext

  alias TrackerWeb.TableParams

  @doc ~S"""
  Renders a data table with optional sorting and pagination.

  ## Examples

      <.data_table id="packages" rows={@streams.packages} table_params={@table_params}
        total_pages={@total_pages} current_page={@current_page}
        has_prev_page?={@has_prev_page?} has_next_page?={@has_next_page?}>
        <:col :let={pkg} field={:name} label="Name" sortable>{pkg.name}</:col>
        <:col :let={pkg} field={:description} label="Description">{pkg.description}</:col>
      </.data_table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :table_params, TableParams, required: true
  attr :row_id, :any, default: nil, doc: "function for generating the row id"
  attr :row_click, :any, default: nil, doc: "function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "function for mapping each row before calling the :col and :action slots"

  attr :total_pages, :integer, default: 0
  attr :current_page, :integer, default: 1
  attr :has_prev_page?, :boolean, default: false
  attr :has_next_page?, :boolean, default: false

  slot :col, required: true do
    attr :field, :atom
    attr :label, :string
    attr :sortable, :boolean
  end

  slot :action, doc: "slot for showing user actions in the last table column"

  def data_table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <figure>
      <table role="grid">
        <thead>
          <tr>
            <th
              :for={col <- @col}
              phx-click={col[:sortable] && "sort"}
              phx-value-field={col[:sortable] && col[:field]}
              style={col[:sortable] && "cursor: pointer"}
            >
              {col[:label]}
              <span :if={col[:sortable]}>
                {TableParams.sort_indicator(@table_params, col[:field])}
              </span>
            </th>
            <th :if={@action != []}>
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}
        >
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            phx-click={@row_click && @row_click.(row)}
            style={@row_click && "cursor: pointer"}
          >
            <td :for={col <- @col}>
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []}>
              <span :for={action <- @action}>
                {render_slot(action, @row_item.(row))}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </figure>

    <nav
      :if={@total_pages > 1}
      style="display: flex; align-items: center; justify-content: center; gap: 0.5rem; margin-top: 1rem;"
    >
      <button
        class="outline secondary"
        style="padding: 0.25rem 0.75rem; font-size: 0.875rem;"
        phx-click="prev-page"
        disabled={!@has_prev_page?}
      >
        &larr;
      </button>
      <small>
        Page {@current_page} of {@total_pages}
      </small>
      <button
        class="outline secondary"
        style="padding: 0.25rem 0.75rem; font-size: 0.875rem;"
        phx-click="next-page"
        disabled={!@has_next_page?}
      >
        &rarr;
      </button>
    </nav>
    """
  end
end
