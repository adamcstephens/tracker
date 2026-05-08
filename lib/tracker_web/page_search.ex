defmodule TrackerWeb.PageSearch do
  @moduledoc """
  Describes the per-page text-search input that the chrome lifts into its
  bottom row. Each list LiveView assigns a `%PageSearch{}` to `:page_search`
  in `handle_params`; the layout renders the form when present.

  Without JS the form GETs to `:action` with the visible search input plus
  any `:hidden` URL params (sort, secondary filters, page) so navigation
  state is preserved. With JS, `phx-change` / `phx-submit` route the named
  event back to the LiveView's existing handler.
  """

  use TypedStruct

  typedstruct do
    field :action, String.t(), enforce: true
    field :placeholder, String.t(), enforce: true
    field :param, String.t(), default: "search"
    field :value, String.t(), default: ""
    field :event, String.t(), default: "search"
    field :hidden, %{String.t() => String.t()}, default: %{}
  end
end
