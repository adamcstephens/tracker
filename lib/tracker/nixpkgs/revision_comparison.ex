defmodule Tracker.Nixpkgs.RevisionComparison do
  @moduledoc """
  Shared, paginated net comparisons for revision show and diff screens.

  `packages/3` compares version and presence; `options/3` compares presence and
  description, type, default, example and read-only metadata. Search and change
  filters apply before pagination, while counts always describe the whole pair.
  Only endpoint payloads for the selected page are loaded into Elixir. A nil
  starting revision means there is no previous revision to compare.
  """

  alias Tracker.Nixpkgs.{ChannelRevision, Option, OptionHistory, OptionSpan, Package, PackageSpan}

  @page_size 15
  @metadata_fields [:description, :type, :default, :example, :read_only]

  defmodule Counts do
    use TypedStruct

    typedstruct do
      field :added, non_neg_integer(), default: 0
      field :removed, non_neg_integer(), default: 0
      field :changed, non_neg_integer(), default: 0
    end
  end

  defmodule PackageRow do
    use TypedStruct

    typedstruct do
      field :attribute, String.t(), enforce: true
      field :old_version, String.t() | nil
      field :new_version, String.t() | nil
      field :type, :added | :removed | :changed, enforce: true
    end
  end

  defmodule OptionRow do
    use TypedStruct

    typedstruct do
      field :name, String.t(), enforce: true
      field :type, :added | :removed | :changed, enforce: true
      field :fields, [OptionHistory.MetadataDiff.t()], default: []
    end
  end

  defmodule Page do
    use TypedStruct

    typedstruct do
      field :results, [PackageRow.t() | OptionRow.t()], default: []
      field :count, non_neg_integer(), default: 0
      field :counts, Counts.t(), default: %Counts{}
      field :page, pos_integer(), default: 1
      field :total_pages, pos_integer(), default: 1
    end
  end

  def packages(from_revision, to_revision, opts \\ [])
  def packages(nil, %ChannelRevision{}, _opts), do: %Page{}

  def packages(%ChannelRevision{} = from_revision, %ChannelRevision{} = to_revision, opts) do
    page = comparison_page(Package, from_revision, to_revision, opts)
    ids = Enum.map(page.results, & &1.id)
    old = package_endpoints(from_revision, ids)
    new = package_endpoints(to_revision, ids)

    rows =
      Enum.map(page.results, fn package ->
        old_span = Map.get(old, package.id)
        new_span = Map.get(new, package.id)

        %PackageRow{
          attribute: package.attribute,
          old_version: get_in(old_span.version),
          new_version: get_in(new_span.version),
          type: change_type(old_span, new_span)
        }
      end)

    %{page | results: rows}
  end

  def options(from_revision, to_revision, opts \\ [])
  def options(nil, %ChannelRevision{}, _opts), do: %Page{}

  def options(%ChannelRevision{} = from_revision, %ChannelRevision{} = to_revision, opts) do
    page = comparison_page(Option, from_revision, to_revision, opts)
    ids = Enum.map(page.results, & &1.id)
    old = option_endpoints(from_revision, ids)
    new = option_endpoints(to_revision, ids)

    rows =
      Enum.map(page.results, fn option ->
        old_span = Map.get(old, option.id)
        new_span = Map.get(new, option.id)
        type = change_type(old_span, new_span)

        %OptionRow{
          name: option.name,
          type: type,
          fields: metadata_fields(type, option.name, old_span, new_span)
        }
      end)

    %{page | results: rows}
  end

  defp comparison_page(resource, %ChannelRevision{} = from, %ChannelRevision{} = to, opts) do
    candidates = candidate_ids(resource, from, to)

    counts = %Counts{
      added: read_page(resource, from, to, candidates, "", "added", 1, 1).count,
      removed: read_page(resource, from, to, candidates, "", "removed", 1, 1).count,
      changed: read_page(resource, from, to, candidates, "", "changed", 1, 1).count
    }

    search = Keyword.get(opts, :search, "")
    change = Keyword.get(opts, :change, "all")
    requested_page = max(Keyword.get(opts, :page, 1), 1)
    result = read_page(resource, from, to, candidates, search, change, requested_page, @page_size)
    total_pages = max(div(result.count + @page_size - 1, @page_size), 1)
    page = min(requested_page, total_pages)

    result =
      if page == requested_page,
        do: result,
        else: read_page(resource, from, to, candidates, search, change, page, @page_size)

    %Page{
      results: result.results,
      count: result.count,
      counts: counts,
      page: page,
      total_pages: total_pages
    }
  end

  # Bound the sorted LIMIT query explicitly so PostgreSQL cannot choose a scan
  # of every alphabetically ordered identity instead of the boundary indexes.
  defp candidate_ids(resource, %ChannelRevision{} = from, %ChannelRevision{} = to)
       when from.channel_id == to.channel_id do
    {lower, upper} =
      if DateTime.compare(from.released_at, to.released_at) == :gt,
        do: {to.released_at, from.released_at},
        else: {from.released_at, to.released_at}

    {span, key} =
      case resource do
        Package -> {PackageSpan, :package_id}
        Option -> {OptionSpan, :option_id}
      end

    span.comparison_candidates!(from.channel_id, lower, upper)
    |> Enum.map(&Map.fetch!(&1, key))
  end

  defp candidate_ids(_resource, %ChannelRevision{}, %ChannelRevision{}), do: nil

  defp read_page(
         resource,
         %ChannelRevision{} = from,
         %ChannelRevision{} = to,
         candidates,
         search,
         change,
         page,
         limit
       ) do
    resource.compare_revisions!(
      from.channel_id,
      from.released_at,
      to.channel_id,
      to.released_at,
      search,
      change,
      %{candidate_ids: candidates},
      page: [offset: (page - 1) * limit, limit: limit, count: true]
    )
  end

  defp package_endpoints(%ChannelRevision{}, []), do: %{}

  defp package_endpoints(%ChannelRevision{} = revision, ids) do
    revision.channel_id
    |> PackageSpan.at_for_packages!(revision.released_at, ids,
      query: [select: [:package_id, :version]]
    )
    |> Map.new(&{&1.package_id, &1})
  end

  defp option_endpoints(%ChannelRevision{}, []), do: %{}

  defp option_endpoints(%ChannelRevision{} = revision, ids) do
    revision.channel_id
    |> OptionSpan.at_for_options!(revision.released_at, ids,
      query: [select: [:option_id | @metadata_fields]]
    )
    |> Map.new(&{&1.option_id, &1})
  end

  defp change_type(nil, %PackageSpan{}), do: :added
  defp change_type(%PackageSpan{}, nil), do: :removed
  defp change_type(%PackageSpan{}, %PackageSpan{}), do: :changed
  defp change_type(nil, %OptionSpan{}), do: :added
  defp change_type(%OptionSpan{}, nil), do: :removed
  defp change_type(%OptionSpan{}, %OptionSpan{}), do: :changed

  defp metadata_fields(:changed, name, %OptionSpan{} = old, %OptionSpan{} = new) do
    for field <- @metadata_fields, Map.fetch!(old, field) != Map.fetch!(new, field) do
      %OptionHistory.MetadataDiff{
        option_name: name,
        field: field,
        old: Map.fetch!(old, field),
        new: Map.fetch!(new, field)
      }
    end
  end

  defp metadata_fields(_type, _name, _old, _new), do: []
end
