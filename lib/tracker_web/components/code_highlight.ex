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
    case Lumis.highlight(code, language: language) do
      {:ok, html} -> html
      {:error, _} -> "<pre><code>#{Phoenix.HTML.html_escape(code)}</code></pre>"
    end
  end
end
