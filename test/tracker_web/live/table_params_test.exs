defmodule TrackerWeb.TableParamsTest do
  use ExUnit.Case, async: true

  alias TrackerWeb.TableParams

  describe "from_params/2" do
    test "returns defaults with empty params" do
      tp = TableParams.from_params(%{})
      assert tp.search == ""
      assert tp.page == 1
      assert tp.offset == 0
      assert tp.page_size == 15
      assert tp.sort_by == nil
      assert tp.sort_dir == :asc
    end

    test "parses search" do
      tp = TableParams.from_params(%{"search" => "hello"})
      assert tp.search == "hello"
    end

    test "reads search from a custom URL key when :search_key is given" do
      tp =
        TableParams.from_params(
          %{"package_search" => "hello", "search" => "ignored"},
          search_key: :package_search
        )

      assert tp.search == "hello"
      assert tp.search_key == :package_search
    end

    test "defaults search_key to :search" do
      tp = TableParams.from_params(%{})
      assert tp.search_key == :search
    end

    test "parses page and calculates offset" do
      tp = TableParams.from_params(%{"page" => "3"})
      assert tp.page == 3
      assert tp.offset == 30
    end

    test "clamps page to minimum of 1" do
      tp = TableParams.from_params(%{"page" => "0"})
      assert tp.page == 1
      assert tp.offset == 0
    end

    test "handles non-integer page gracefully" do
      tp = TableParams.from_params(%{"page" => "abc"})
      assert tp.page == 1
      assert tp.offset == 0
    end

    test "parses sort_by from allowed_sorts" do
      tp = TableParams.from_params(%{"sort_by" => "name"}, allowed_sorts: ~w(name date)a)
      assert tp.sort_by == :name
    end

    test "falls back to default_sort when sort_by not in allowed_sorts" do
      tp =
        TableParams.from_params(%{"sort_by" => "invalid"},
          allowed_sorts: ~w(name)a,
          default_sort: :name
        )

      assert tp.sort_by == :name
    end

    test "falls back to default_sort when sort_by is not an existing atom" do
      tp =
        TableParams.from_params(%{"sort_by" => "nonexistent_atom_xyz"},
          allowed_sorts: ~w(name)a,
          default_sort: :name
        )

      assert tp.sort_by == :name
    end

    test "parses sort_dir" do
      tp = TableParams.from_params(%{"sort_dir" => "desc"}, default_sort_dir: :asc)
      assert tp.sort_dir == :desc
    end

    test "falls back to default_sort_dir for invalid sort_dir" do
      tp = TableParams.from_params(%{"sort_dir" => "invalid"}, default_sort_dir: :desc)
      assert tp.sort_dir == :desc
    end

    test "uses default_sort and default_sort_dir when no sort params given" do
      tp =
        TableParams.from_params(%{},
          allowed_sorts: ~w(number title)a,
          default_sort: :number,
          default_sort_dir: :desc
        )

      assert tp.sort_by == :number
      assert tp.sort_dir == :desc
    end

    test "respects custom page_size" do
      tp = TableParams.from_params(%{"page" => "2"}, page_size: 25)
      assert tp.page_size == 25
      assert tp.offset == 25
    end
  end

  describe "to_query_params/2" do
    test "omits default values" do
      tp = TableParams.from_params(%{})
      assert TableParams.to_query_params(tp) == %{}
    end

    test "includes search when non-empty" do
      tp = TableParams.from_params(%{"search" => "hello"})
      assert TableParams.to_query_params(tp) == %{search: "hello"}
    end

    test "writes search under the custom :search_key" do
      tp =
        TableParams.from_params(
          %{"package_search" => "hello"},
          search_key: :package_search
        )

      assert TableParams.to_query_params(tp) == %{package_search: "hello"}
    end

    test "includes page when > 1" do
      tp = TableParams.from_params(%{"page" => "2"})
      assert TableParams.to_query_params(tp) == %{page: 2}
    end

    test "includes sort_by when different from default" do
      tp =
        TableParams.from_params(%{"sort_by" => "title"},
          allowed_sorts: ~w(number title)a,
          default_sort: :number
        )

      assert %{sort_by: :title} = TableParams.to_query_params(tp)
    end

    test "includes sort_dir when different from default" do
      tp = TableParams.from_params(%{"sort_dir" => "desc"}, default_sort_dir: :asc)
      assert %{sort_dir: :desc} = TableParams.to_query_params(tp)
    end

    test "merges extra params" do
      tp = TableParams.from_params(%{"search" => "hello"})
      result = TableParams.to_query_params(tp, %{base_ref: "main"})
      assert result == %{search: "hello", base_ref: "main"}
    end

    test "omits extra params with empty string values" do
      tp = TableParams.from_params(%{})
      result = TableParams.to_query_params(tp, %{base_ref: "", channel: "stable"})
      assert result == %{channel: "stable"}
    end
  end

  describe "to_path/3" do
    test "returns base path with no params" do
      tp = TableParams.from_params(%{})
      assert TableParams.to_path(tp, "/packages") == "/packages"
    end

    test "appends query string" do
      tp = TableParams.from_params(%{"search" => "hello", "page" => "2"})
      path = TableParams.to_path(tp, "/packages")
      assert String.starts_with?(path, "/packages?")
      query = path |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert query == %{"page" => "2", "search" => "hello"}
    end

    test "merges extra params into path" do
      tp = TableParams.from_params(%{"search" => "hello"})
      path = TableParams.to_path(tp, "/changes", %{base_ref: "main"})
      assert String.starts_with?(path, "/changes?")
      query = path |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert query == %{"base_ref" => "main", "search" => "hello"}
    end

    test "uses the custom :search_key when building the path" do
      tp =
        TableParams.from_params(
          %{"package_search" => "hello"},
          search_key: :package_search
        )

      path = TableParams.to_path(tp, "/teams/foo")
      query = path |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert query == %{"package_search" => "hello"}
    end
  end

  describe "changed?/2" do
    test "returns false for identical params" do
      tp = TableParams.from_params(%{"search" => "hello", "page" => "2"})
      refute TableParams.changed?(tp, tp)
    end

    test "returns true when search differs" do
      tp1 = TableParams.from_params(%{"search" => "hello"})
      tp2 = TableParams.from_params(%{"search" => "world"})
      assert TableParams.changed?(tp1, tp2)
    end

    test "returns true when page differs" do
      tp1 = TableParams.from_params(%{"page" => "1"})
      tp2 = TableParams.from_params(%{"page" => "2"})
      assert TableParams.changed?(tp1, tp2)
    end

    test "returns true when sort changes" do
      tp1 = TableParams.from_params(%{}, allowed_sorts: ~w(name)a, default_sort: :name)

      tp2 =
        TableParams.from_params(%{"sort_dir" => "desc"},
          allowed_sorts: ~w(name)a,
          default_sort: :name
        )

      assert TableParams.changed?(tp1, tp2)
    end

    test "returns true when first arg is nil" do
      tp = TableParams.from_params(%{})
      assert TableParams.changed?(nil, tp)
    end
  end

  describe "toggle_dir/1" do
    test "toggles asc to desc" do
      assert TableParams.toggle_dir(:asc) == :desc
    end

    test "toggles desc to asc" do
      assert TableParams.toggle_dir(:desc) == :asc
    end
  end

  describe "sort_indicator/2" do
    test "returns up arrow for matching field with asc" do
      tp =
        TableParams.from_params(%{"sort_by" => "name"},
          allowed_sorts: ~w(name)a,
          default_sort: :name
        )

      assert TableParams.sort_indicator(tp, :name) == "↑"
    end

    test "returns down arrow for matching field with desc" do
      tp =
        TableParams.from_params(%{"sort_by" => "name", "sort_dir" => "desc"},
          allowed_sorts: ~w(name)a,
          default_sort: :name,
          default_sort_dir: :asc
        )

      assert TableParams.sort_indicator(tp, :name) == "↓"
    end

    test "returns empty string for non-matching field" do
      tp =
        TableParams.from_params(%{"sort_by" => "name"},
          allowed_sorts: ~w(name date)a,
          default_sort: :name
        )

      assert TableParams.sort_indicator(tp, :date) == ""
    end
  end

  describe "apply_pagination/3" do
    test "assigns pagination state from Ash page result" do
      tp = TableParams.from_params(%{"page" => "2"})

      page_result = %{
        count: 45,
        results: [:item1, :item2],
        more?: true
      }

      assigns = TableParams.apply_pagination(tp, page_result, :items)

      assert assigns.has_prev_page? == true
      assert assigns.has_next_page? == true
      assert assigns.total_pages == 3
      assert assigns.current_page == 2
      assert assigns.stream_name == :items
      assert assigns.stream_results == [:item1, :item2]
    end

    test "first page has no prev" do
      tp = TableParams.from_params(%{})

      page_result = %{count: 30, results: [:a], more?: true}
      assigns = TableParams.apply_pagination(tp, page_result, :items)

      assert assigns.has_prev_page? == false
      assert assigns.current_page == 1
    end

    test "handles zero count" do
      tp = TableParams.from_params(%{})

      page_result = %{count: 0, results: [], more?: false}
      assigns = TableParams.apply_pagination(tp, page_result, :items)

      assert assigns.total_pages == 0
      assert assigns.has_prev_page? == false
      assert assigns.has_next_page? == false
    end
  end
end
