defmodule TrackerWeb.ReconstructionJobController do
  @moduledoc """
  Multipart endpoint a reconstruction worker uses to submit the rebuilt
  comparison artifact. JSON:API can't model multipart bodies cleanly, so
  this lives as a plain Phoenix controller rather than under the AshJsonApi
  router.
  """
  use TrackerWeb, :controller

  alias Tracker.Nixpkgs.ReconstructionJob

  def result(conn, %{"id" => id, "comparison_zip" => %Plug.Upload{path: path}}) do
    lease_token = get_req_header(conn, "x-lease-token") |> List.first()

    cond do
      is_nil(lease_token) or lease_token == "" ->
        send_error(conn, 400, "missing_lease_token")

      true ->
        zip_bytes = File.read!(path)
        actor = conn.assigns.current_user

        case ReconstructionJob.submit_result(id, lease_token, zip_bytes, actor: actor) do
          {:ok, payload} ->
            conn
            |> put_status(200)
            |> json(payload)

          {:error, %Ash.Error.Forbidden{}} ->
            send_error(conn, 403, "forbidden")

          {:error, error} ->
            send_error(conn, 422, reason_for(error))
        end
    end
  end

  def result(conn, _params), do: send_error(conn, 400, "missing_comparison_zip")

  defp send_error(conn, status, reason) do
    conn
    |> put_status(status)
    |> json(%{error: reason})
  end

  defp reason_for(%Ash.Error.Unknown{errors: [%{error: msg} | _]}), do: msg
  defp reason_for(other), do: inspect(other)
end
