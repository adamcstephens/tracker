defmodule TrackerWeb.SectionHeaderTest do
  use TrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  alias TrackerWeb.SectionHeader

  describe "section_header/1" do
    test "renders the title, a rule, and the count" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionHeader.section_header title="Packages" count={3} />
        """)

      assert html =~ ~s(class="section-header")
      assert html =~ "<h2>Packages</h2>"
      assert html =~ ~s(<span class="rule">)
      assert html =~ ~s(<span class="n">3</span>)
    end
  end
end
