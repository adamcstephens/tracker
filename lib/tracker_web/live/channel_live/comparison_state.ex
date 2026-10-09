defmodule TrackerWeb.ChannelLive.ComparisonState do
  import Phoenix.Component, only: [assign: 2]

  alias Tracker.Nixpkgs.RevisionComparison
  alias TrackerWeb.{Lens, PageSearch, Time}

  def load(socket, channel, from, to, params) do
    search = Map.get(params, "search", "")
    change = Map.get(params, "change", "all")

    package_page =
      RevisionComparison.packages(from, to,
        page: page(params["page"]),
        search: search,
        change: change
      )

    option_page =
      RevisionComparison.options(from, to, page: page(params["option_page"]), search: search)

    uri = URI.parse(socket.assigns.current_path)
    query = URI.decode_query(uri.query || "")

    query =
      query
      |> Map.put("page", to_string(package_page.page))
      |> Map.put("option_page", to_string(option_page.page))

    lens = socket.assigns.lens && %{socket.assigns.lens | disabled?: true}

    lens_path =
      if Lens.canonical(lens) != {channel, to.revision},
        do: Lens.path_for(socket.assigns.current_path, channel, to.revision)

    assign(socket,
      channel: channel,
      revision: to,
      previous_revision: from,
      lens: lens,
      lens_path: lens_path,
      formatted_released_at: Time.format_datetime(to.released_at, socket.assigns.time_zone),
      package_page: package_page,
      option_page: option_page,
      change: change,
      filter_paths:
        Map.new(["all", "changed", "added", "removed"], fn value ->
          {value, path(uri.path, query |> Map.put("change", value) |> Map.delete("page"))}
        end),
      comparison_query: query,
      comparison_path: uri.path,
      from_path: from && "/channels/#{channel}/revisions/#{from.revision}",
      to_path: "/channels/#{channel}/revisions/#{to.revision}",
      package_prev_path: path(uri.path, query, "page", package_page.page - 1),
      package_next_path: path(uri.path, query, "page", package_page.page + 1),
      option_prev_path: path(uri.path, query, "option_page", option_page.page - 1),
      option_next_path: path(uri.path, query, "option_page", option_page.page + 1),
      page_search: %PageSearch{
        action: uri.path,
        value: search,
        placeholder: "Search changed packages and options…",
        hidden: Map.drop(query, ["search", "page", "option_page"]),
        clear_to:
          path(uri.path, query |> Map.delete("search") |> Map.drop(["page", "option_page"]))
      }
    )
  end

  def search(socket, search) do
    query =
      socket.assigns.comparison_query
      |> Map.put("search", search)
      |> Map.drop(["page", "option_page"])

    Phoenix.LiveView.push_patch(socket,
      to: path(socket.assigns.comparison_path, query),
      replace: true
    )
  end

  defp page(nil), do: 1

  defp page(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> 1
    end
  end

  defp path(base, query, key, value), do: path(base, Map.put(query, key, to_string(value)))
  defp path(base, query), do: base <> "?" <> URI.encode_query(query)
end
