defmodule TrackerWeb.CodeHighlight do
  @moduledoc """
  Syntax highlighting for code blocks using Lumis.
  """

  use Phoenix.Component

  @doc """
  Renders a syntax-highlighted code block.

  ## Attributes

    * `code` - The source code to highlight
    * `language` - The language for syntax highlighting (default: "nix")
  """
  attr :code, :string, required: true
  attr :language, :string, default: "nix"

  def code_block(assigns) do
    highlighted = highlight(assigns.code, assigns.language)
    assigns = assign(assigns, :highlighted, highlighted)

    ~H"""
    {Phoenix.HTML.raw(@highlighted)}
    """
  end

  defp highlight(code, language) do
    # html_linked emits class names instead of inline theme colors, so the
    # stylesheets linked in root.html.heex can follow prefers-color-scheme.
    {:ok, html} = Lumis.highlight(code, formatter: {:html_linked, language: language})
    html
  rescue
    Lumis.HighlightError ->
      {:safe, escaped} = Phoenix.HTML.html_escape(code)
      "<pre><code>#{escaped}</code></pre>"
  end
end
