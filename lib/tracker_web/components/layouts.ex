defmodule TrackerWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use TrackerWeb, :controller` and
  `use TrackerWeb, :live_view`.
  """
  use TrackerWeb, :html

  embed_templates "layouts/*"

  def active_nav?(view, prefix) when is_atom(view) do
    case Module.split(view) do
      [_, ^prefix | _] -> true
      _ -> false
    end
  end

  def active_nav?(_view, _prefix), do: false
end
