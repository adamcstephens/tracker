defmodule Tracker.Nixpkgs.UpdateLogPageWorkerTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.UpdateLogPage
  alias Tracker.Nixpkgs.UpdateLogPageWorker

  @base "https://nixpkgs-update-logs.nix-community.org/"

  test "reconciles direct directory links, replaces changed URLs, and removes stale rows" do
    UpdateLogPage.upsert!("stale", @base <> "stale/")
    UpdateLogPage.upsert!("old", @base <> "previous-old/")

    html =
      index("""
      <a href="old/">old/</a>
      <a href="new/">new/</a>
      <a href="./nested/">nested/</a>
      <a href="../">../</a>
      <a href="https://elsewhere.example/external/">external/</a>
      <a href="file.txt">file.txt</a>
      """)

    assert {:ok, %{updated: 2, removed: 1}} =
             UpdateLogPageWorker.run(fetch: fn -> {:ok, html} end)

    assert Map.new(UpdateLogPage.read!(), &{&1.attribute, &1.url}) == %{
             "old" => @base <> "old/",
             "new" => @base <> "new/"
           }

    ids = Map.new(UpdateLogPage.read!(), &{&1.attribute, &1.id})

    assert {:ok, %{updated: 0, removed: 0}} =
             UpdateLogPageWorker.run(fetch: fn -> {:ok, html} end)

    assert Map.new(UpdateLogPage.read!(), &{&1.attribute, &1.id}) == ids
  end

  test "retains stored rows after HTTP or index parsing failure" do
    UpdateLogPage.upsert!("retained", @base <> "retained/")

    assert {:error, {:unexpected_status, 503}} =
             UpdateLogPageWorker.run(fetch: fn -> {:error, {:unexpected_status, 503}} end)

    assert {:error, :invalid_index} =
             UpdateLogPageWorker.run(
               fetch: fn -> {:ok, "<html><a href='new/'>new/</a></html>"} end
             )

    assert {:error, :empty_index} =
             UpdateLogPageWorker.run(fetch: fn -> {:ok, index("<a href='../'>../</a>")} end)

    assert Map.new(UpdateLogPage.read!(), &{&1.attribute, &1.url}) == %{
             "retained" => @base <> "retained/"
           }
  end

  test "rejects unsafe paths while decoding valid encoded directory names" do
    html =
      index("""
      <a href="agdaPackages.%31lab/">agdaPackages.1lab/</a>
      <a href="%2E%2E/">../</a>
      <a href="other%2Fchild/">other/child/</a>
      <a href="bad%ZZ/">bad/</a>
      <a href="empty//">empty//</a>
      <a href="?next/">query</a>
      <a href="has%5Cslash/">backslash</a>
      """)

    assert {:ok, %{"agdaPackages.1lab" => @base <> "agdaPackages.%31lab/"}} =
             UpdateLogPageWorker.parse_index(html)
  end

  defp index(anchors), do: "<html><h1>Index of /</h1><pre>#{anchors}</pre></html>"
end
