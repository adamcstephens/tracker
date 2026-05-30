defmodule TrackerWeb.ChannelDiffController do
  use TrackerWeb, :controller

  def resolve(conn, %{"channel" => channel, "compare" => [a, b | _]}) do
    redirect(conn, to: ~p"/channels/#{channel}/diff/#{a}/#{b}")
  end

  def resolve(conn, %{"channel" => channel}) do
    conn
    |> put_flash(:error, "Select two revisions to compare.")
    |> redirect(to: ~p"/channels/#{channel}")
  end
end
