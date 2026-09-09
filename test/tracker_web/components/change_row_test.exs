defmodule TrackerWeb.ChangeRowTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  alias TrackerWeb.ChangeRow

  defp change do
    %Tracker.Nixpkgs.Change{
      number: 4242,
      title: "python3Packages.numpy: 2.0.0 -> 2.1.0",
      state: :merged,
      url: "https://github.com/NixOS/nixpkgs/pull/4242",
      base_ref: "master",
      merged_at: ~U[2026-04-01 10:00:00Z]
    }
  end

  describe "change_row_list/1" do
    test "declares the flags every Change list shares and passes globals through" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ChangeRow.change_row_list id="changes" phx-update="stream"></ChangeRow.change_row_list>
        """)

      assert html =~ ~s(id="changes")
      assert html =~ ~s(phx-update="stream")
      assert html =~ "row-list--stacked"
      assert html =~ "row-list--reserve-meta"
      assert html =~ "row-list--truncate-label"
    end
  end

  describe "change_row/1" do
    test "renders the number, title, state pill, base branch, merge date and GitHub link" do
      assigns = %{change: change()}

      html =
        rendered_to_string(~H"""
        <ChangeRow.change_row_list id="changes">
          <ChangeRow.change_row change={@change} />
        </ChangeRow.change_row_list>
        """)

      assert html =~ ~s(<span class="row-num">#4242</span>)
      assert html =~ "python3Packages.numpy: 2.0.0 -&gt; 2.1.0"
      assert html =~ ~s(class="pill pill-merged")
      assert html =~ "master"
      assert html =~ "Merged on 2026-04-01 10:00 UTC"
      assert html =~ ~s(href="https://github.com/NixOS/nixpkgs/pull/4242")
      assert html =~ ~s(aria-label="Open #4242 on GitHub")
    end

    test "the whole row navigates to the change" do
      assigns = %{change: change()}

      html =
        rendered_to_string(~H"""
        <ChangeRow.change_row_list id="changes">
          <ChangeRow.change_row change={@change} />
        </ChangeRow.change_row_list>
        """)

      assert [_] = Floki.find(Floki.parse_document!(html), ~s(a.row-link[href="/changes/4242"]))
    end

    test "an unmerged change leaves the meta empty" do
      assigns = %{change: %{change() | state: :open, merged_at: nil}}

      html =
        rendered_to_string(~H"""
        <ChangeRow.change_row_list id="changes">
          <ChangeRow.change_row change={@change} />
        </ChangeRow.change_row_list>
        """)

      assert html =~ ~s(class="pill pill-open")
      refute html =~ "Merged on"
    end

    test "the landed pill appears only when a channel is passed" do
      assigns = %{change: change()}

      html =
        rendered_to_string(~H"""
        <ChangeRow.change_row_list id="changes">
          <ChangeRow.change_row change={@change} landed_in="nixos-unstable" />
        </ChangeRow.change_row_list>
        """)

      assert html =~ ~s(class="pill pill-landed")
      assert html =~ "in nixos-unstable"
    end

    test "no landed pill without a channel" do
      assigns = %{change: change()}

      html =
        rendered_to_string(~H"""
        <ChangeRow.change_row_list id="changes">
          <ChangeRow.change_row change={@change} />
        </ChangeRow.change_row_list>
        """)

      refute html =~ "pill-landed"
    end
  end
end
