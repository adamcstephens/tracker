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

    test "respects custom page_size" do
      tp = TableParams.from_params(%{"page" => "2"}, page_size: 25)
      assert tp.page_size == 25
      assert tp.offset == 25
    end

    test "carries the lens params so generated links keep the lens" do
      tp =
        TableParams.from_params(%{
          "page" => "2",
          "channel" => "nixos-unstable",
          "rev" => "deadbeef"
        })

      assert tp.channel == "nixos-unstable"
      assert tp.rev == "deadbeef"

      query =
        tp |> TableParams.to_path("/packages") |> URI.parse() |> Map.fetch!(:query)

      assert URI.decode_query(query) == %{
               "page" => "2",
               "channel" => "nixos-unstable",
               "rev" => "deadbeef"
             }
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

  describe "to_hidden_inputs/2" do
    test "omits :page so a fresh search resets to the first page (trk-278)" do
      tp = TableParams.from_params(%{"search" => "hello", "page" => "3"})
      refute Map.has_key?(TableParams.to_hidden_inputs(tp), "page")
    end

    test "excludes the visible search input" do
      tp = TableParams.from_params(%{"search" => "hello", "page" => "3"})
      refute Map.has_key?(TableParams.to_hidden_inputs(tp), "search")
    end

    test "preserves extra filters while dropping page" do
      tp = TableParams.from_params(%{"page" => "3"})
      assert TableParams.to_hidden_inputs(tp, %{base_ref: "main"}) == %{"base_ref" => "main"}
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

    test "returns true when first arg is nil" do
      tp = TableParams.from_params(%{})
      assert TableParams.changed?(nil, tp)
    end
  end
end
