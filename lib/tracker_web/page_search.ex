defmodule TrackerWeb.PageSearch do
  @moduledoc """
  Describes the global search input rendered in the chrome's bottom row.
  Every LiveView assigns a `%PageSearch{}` to `:page_search` in
  `handle_params`; the layout renders the form on every page.

  Three modes:

    * `:active` — the page filters its own data on this search. The form
      wires `phx-change` / `phx-submit` to the LV's event handler and the
      `UpdateURL` JS hook keeps the URL in sync. Hidden inputs preserve
      sort/page/secondary filters for the no-JS GET fallback.
    * `:passthrough` — the page itself doesn't filter, but submitting
      navigates to a sensible parent index (`:action`) with the query
      applied. The form is a plain GET; pressing Enter sends the user to
      that section.
    * `:inert` — the box is rendered disabled. It echoes the persisted
      query so users see context, but typing/submitting does nothing.
      Used for pages where no parent index search makes sense (Channels).

  The `:value` is sourced from the URL `?search=` param so cross-section
  navigation (which appends the param to chrome links) carries the query.
  """

  use TypedStruct

  typedstruct do
    field :mode, :active | :passthrough | :inert, default: :active
    field :action, String.t(), default: nil
    field :placeholder, String.t(), default: "Search…"
    field :param, String.t(), default: "search"
    field :value, String.t(), default: ""
    field :event, String.t(), default: "search"
    field :hidden, %{String.t() => String.t()}, default: %{}
    # Where the clear (×) button lands; nil falls back to :action + :hidden.
    field :clear_to, String.t() | nil, default: nil
  end
end
