defmodule TrackerWeb.TableParams do
  @moduledoc """
  Centralizes URL parameter parsing, pagination, and sort handling for LiveView tables.
  """

  use TypedStruct

  typedstruct do
    field :search, String.t(), default: ""
    field :search_key, atom(), default: :search
    field :page, pos_integer(), default: 1
    field :offset, non_neg_integer(), default: 0
    field :page_size, pos_integer(), default: 15
    field :sort_by, atom(), default: nil
    field :sort_dir, :asc | :desc, default: :asc
    field :default_sort, atom(), default: nil
    field :default_sort_dir, :asc | :desc, default: :asc
  end

  @doc """
  Parse URL params into a TableParams struct.

  ## Options

    * `:allowed_sorts` - list of atoms for valid sort fields
    * `:default_sort` - default sort field atom (default: nil)
    * `:default_sort_dir` - default sort direction, :asc or :desc (default: :asc)
    * `:page_size` - number of items per page (default: 15)
    * `:search_key` - atom URL key the search input writes to (default: `:search`).
      Set to e.g. `:package_search` when an inner table shares a page with the
      global `?search=` so the two inputs don't fight over one URL slot.
  """
  @spec from_params(map(), keyword()) :: t()
  def from_params(params, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, 15)
    allowed_sorts = Keyword.get(opts, :allowed_sorts, [])
    default_sort = Keyword.get(opts, :default_sort, nil)
    default_sort_dir = Keyword.get(opts, :default_sort_dir, :asc)
    search_key = Keyword.get(opts, :search_key, :search)

    search = Map.get(params, Atom.to_string(search_key), "")
    page = parse_page(params["page"])
    offset = (page - 1) * page_size
    sort_by = parse_sort_by(params["sort_by"], allowed_sorts, default_sort)
    sort_dir = parse_sort_dir(params["sort_dir"], default_sort_dir)

    %__MODULE__{
      search: search,
      search_key: search_key,
      page: page,
      offset: offset,
      page_size: page_size,
      sort_by: sort_by,
      sort_dir: sort_dir,
      default_sort: default_sort,
      default_sort_dir: default_sort_dir
    }
  end

  @doc """
  Convert TableParams to a query params map, omitting default values.
  Optionally merges extra params (empty string values are omitted).
  """
  @spec to_query_params(t(), map()) :: map()
  def to_query_params(%__MODULE__{} = tp, extras \\ %{}) do
    params =
      %{}
      |> maybe_put(tp.search_key, tp.search, "")
      |> maybe_put(:page, tp.page, 1)
      |> maybe_put(:sort_by, tp.sort_by, tp.default_sort)
      |> maybe_put(:sort_dir, tp.sort_dir, tp.default_sort_dir)

    extras
    |> Enum.reject(fn {_k, v} -> v in ["", nil, false] end)
    |> Map.new()
    |> Map.merge(params)
  end

  @doc """
  Convert TableParams to a string-keyed map suitable for `<input type="hidden">`
  fallbacks on a search form. Excludes `:search` (the visible input) and any
  default-valued params; merges extras using the same omit-empty rules as
  `to_query_params/2`.
  """
  @spec to_hidden_inputs(t(), map()) :: %{String.t() => String.t()}
  def to_hidden_inputs(%__MODULE__{} = tp, extras \\ %{}) do
    tp
    |> to_query_params(extras)
    |> Map.delete(tp.search_key)
    |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  @doc """
  Build a URL path with query params, omitting defaults.
  """
  @spec to_path(t(), String.t(), map()) :: String.t()
  def to_path(%__MODULE__{} = tp, base_path, extras \\ %{}) do
    case tp |> to_query_params(extras) |> URI.encode_query() do
      "" -> base_path
      qs -> "#{base_path}?#{qs}"
    end
  end

  @doc """
  Returns true if any table params have changed (triggering a data reload).
  Returns true if the first argument is nil (initial load).
  """
  @spec changed?(t() | nil, t()) :: boolean()
  def changed?(nil, %__MODULE__{}), do: true
  def changed?(%__MODULE__{} = old, %__MODULE__{} = new), do: old != new

  @doc """
  Toggle sort direction.
  """
  @spec toggle_dir(:asc | :desc) :: :asc | :desc
  def toggle_dir(:asc), do: :desc
  def toggle_dir(:desc), do: :asc

  @doc """
  Returns a sort indicator string for the given field.
  """
  @spec sort_indicator(t(), atom()) :: String.t()
  def sort_indicator(%__MODULE__{sort_by: field, sort_dir: :asc}, field), do: "↑"
  def sort_indicator(%__MODULE__{sort_by: field, sort_dir: :desc}, field), do: "↓"
  def sort_indicator(%__MODULE__{}, _field), do: ""

  @doc """
  Compute pagination assigns from an Ash page result.

  Returns a map with:
    * `:has_prev_page?` - boolean
    * `:has_next_page?` - boolean
    * `:total_pages` - integer
    * `:current_page` - integer
    * `:stream_name` - the atom to use for stream
    * `:stream_results` - the results list
  """
  @spec apply_pagination(t(), map(), atom()) :: map()
  def apply_pagination(%__MODULE__{} = tp, page_result, stream_name) do
    total_pages = if page_result.count > 0, do: ceil(page_result.count / tp.page_size), else: 0
    current_page = div(tp.offset, tp.page_size) + 1

    %{
      has_prev_page?: tp.offset > 0,
      has_next_page?: page_result.more?,
      total_pages: total_pages,
      current_page: current_page,
      stream_name: stream_name,
      stream_results: page_result.results
    }
  end

  defp parse_page(nil), do: 1

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> max(n, 1)
      :error -> 1
    end
  end

  defp parse_sort_by(nil, _allowed, default), do: default

  defp parse_sort_by(field, allowed, default) when is_binary(field) do
    atom = String.to_existing_atom(field)
    if atom in allowed, do: atom, else: default
  rescue
    ArgumentError -> default
  end

  defp parse_sort_dir("asc", _default), do: :asc
  defp parse_sort_dir("desc", _default), do: :desc
  defp parse_sort_dir(_, default), do: default

  defp maybe_put(map, _key, value, value), do: map
  defp maybe_put(map, _key, nil, _default), do: map
  defp maybe_put(map, key, value, _default), do: Map.put(map, key, value)
end
