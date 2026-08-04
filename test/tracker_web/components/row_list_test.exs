defmodule TrackerWeb.RowListTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  alias TrackerWeb.RowList

  describe "row_list/1" do
    test "renders a single card list with the given id and passes globals through" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things" phx-hook="AnchorExpand">
          <RowList.row mode={:plain}>
            <:label>alpha</:label>
          </RowList.row>
        </RowList.row_list>
        """)

      assert html =~ ~s(id="things")
      assert html =~ ~s(class="row-list")
      assert html =~ ~s(phx-hook="AnchorExpand")
      assert html =~ "alpha"
    end

    test "stacked lists opt into the narrow-screen two-line layout" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things" stacked>
          <RowList.row mode={:plain}>
            <:label>alpha</:label>
          </RowList.row>
        </RowList.row_list>
        """)

      assert html =~ ~s(class="row-list row-list--stacked")
    end
  end

  # ui.js walks rows with this selector. Asserting it here keeps the markup and
  # the key handler from drifting apart.
  describe "keyboard row navigation reaches every row (TRK-376)" do
    @row_selector "ul.row-list > li > .row-line, ul.row-list > li > details > summary"

    test "all three modes expose exactly one focusable line" do
      assigns = %{}

      rows =
        rendered_to_string(~H"""
        <RowList.row_list id="things">
          <RowList.row mode={:plain}>
            <:label>plain</:label>
          </RowList.row>
          <RowList.row mode={:link} navigate="/alpha">
            <:label>link</:label>
          </RowList.row>
          <RowList.row mode={:expandable}>
            <:label>expandable</:label>
            <:body>detail</:body>
          </RowList.row>
        </RowList.row_list>
        """)
        |> Floki.parse_document!()
        |> Floki.find(@row_selector)

      assert length(rows) == 3
      assert Floki.text(rows) =~ "plain"
      assert Floki.text(rows) =~ "link"
      assert Floki.text(rows) =~ "expandable"
    end

    test "a list nested in a row body contributes its rows after that row" do
      assigns = %{}

      labels =
        rendered_to_string(~H"""
        <RowList.row_list id="outer">
          <RowList.row mode={:expandable}>
            <:label>outer-first</:label>
            <:body>
              <RowList.row_list id="inner">
                <RowList.row mode={:plain}>
                  <:label>inner</:label>
                </RowList.row>
              </RowList.row_list>
            </:body>
          </RowList.row>
          <RowList.row mode={:plain}>
            <:label>outer-second</:label>
          </RowList.row>
        </RowList.row_list>
        """)
        |> Floki.parse_document!()
        |> Floki.find(@row_selector)
        |> Enum.map(&(Floki.find(&1, ".row-label") |> Floki.text()))

      assert labels == ["outer-first", "inner", "outer-second"]
    end
  end

  describe "row/1 leading and sublabel slots" do
    test "renders a leading affordance ahead of the label" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things">
          <RowList.row mode={:plain}>
            <:leading><span class="glyph">*</span></:leading>
            <:label>alpha</:label>
          </RowList.row>
        </RowList.row_list>
        """)

      assert html =~ ~s(class="row-line row-line--leading")
      assert html =~ ~s(class="row-leading")
      assert html =~ ~s(<span class="glyph">*</span>)
    end

    test "renders a sublabel beneath the label" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things">
          <RowList.row mode={:plain}>
            <:label>alpha</:label>
            <:sublabel>subscribed 3 days ago</:sublabel>
          </RowList.row>
        </RowList.row_list>
        """)

      assert html =~ ~s(class="row-body")
      assert html =~ ~s(class="row-sublabel")
      assert html =~ "subscribed 3 days ago"
    end

    test "omits the body wrapper and leading modifier when neither slot is given" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things">
          <RowList.row mode={:plain}>
            <:label>alpha</:label>
          </RowList.row>
        </RowList.row_list>
        """)

      refute html =~ "row-body"
      refute html =~ "row-line--leading"
    end
  end

  describe "row ids" do
    test "the id lands on the li so streams and tests can address the whole row" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things">
          <RowList.row id="row-alpha" mode={:link} navigate="/alpha">
            <:label>alpha</:label>
          </RowList.row>
        </RowList.row_list>
        """)

      assert html =~ ~s(<li id="row-alpha">)
    end

    test "expandable rows keep the id on the li too" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things">
          <RowList.row id="row-alpha" mode={:expandable}>
            <:label>alpha</:label>
            <:body>detail</:body>
          </RowList.row>
        </RowList.row_list>
        """)

      assert html =~ ~s(<li id="row-alpha">)
      refute html =~ ~s(<details id=)
    end
  end

  describe "row/1 expandable mode" do
    test "renders a details row with the body in the panel" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things">
          <RowList.row id="row-alpha" mode={:expandable}>
            <:label>alpha</:label>
            <:meta>boolean</:meta>
            <:actions><button type="button">copy</button></:actions>
            <:body>the detail</:body>
          </RowList.row>
        </RowList.row_list>
        """)

      assert html =~ "<details"
      assert html =~ ~s(id="row-alpha")
      assert html =~ "<summary"
      assert html =~ "the detail"
      assert html =~ ~s(class="row-label")
      assert html =~ ~s(class="row-meta")
      assert html =~ ~s(class="row-actions")
    end

    test "opens the row when open is set" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things">
          <RowList.row id="row-alpha" mode={:expandable} open>
            <:label>alpha</:label>
            <:body>the detail</:body>
          </RowList.row>
        </RowList.row_list>
        """)

      assert html =~ "open"
    end

    test "falls back to a plain row when there is no body" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things">
          <RowList.row id="row-alpha" mode={:expandable}>
            <:label>alpha</:label>
          </RowList.row>
        </RowList.row_list>
        """)

      refute html =~ "<details"
      assert html =~ "alpha"
    end
  end

  describe "row/1 link mode" do
    test "wraps the whole row in a navigation link" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things">
          <RowList.row mode={:link} navigate="/options/services.nginx">
            <:label>nginx</:label>
            <:meta>3 options</:meta>
          </RowList.row>
        </RowList.row_list>
        """)

      assert html =~ ~s(href="/options/services.nginx")
      assert html =~ ~s(data-phx-link="redirect")
      assert html =~ ~s(class="row-line row-link")
      refute html =~ "<details"
    end
  end

  describe "row/1 plain mode" do
    test "renders a bare row with no link or disclosure" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things">
          <RowList.row mode={:plain}>
            <:label>alpha</:label>
          </RowList.row>
        </RowList.row_list>
        """)

      refute html =~ "<details"
      refute html =~ "<a"
      assert html =~ ~s(class="row-line")
    end

    test "the line takes a programmatic focus target, since it has no native one" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things">
          <RowList.row mode={:plain}>
            <:label>alpha</:label>
          </RowList.row>
        </RowList.row_list>
        """)

      assert html =~ ~s(tabindex="-1")
    end

    test "link and expandable rows are left to their native focusables" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RowList.row_list id="things">
          <RowList.row mode={:link} navigate="/alpha">
            <:label>alpha</:label>
          </RowList.row>
          <RowList.row mode={:expandable}>
            <:label>beta</:label>
            <:body>detail</:body>
          </RowList.row>
        </RowList.row_list>
        """)

      refute html =~ ~s(tabindex)
    end
  end
end
