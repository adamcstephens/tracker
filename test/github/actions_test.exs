defmodule GitHub.ActionsTest do
  use ExUnit.Case, async: true

  alias GitHub.Actions
  alias GitHub.Actions.Artifact
  alias GitHub.Error

  test "returns comparison artifacts beyond the first page in response order" do
    Req.Test.stub(__MODULE__, fn conn ->
      case Plug.Conn.fetch_query_params(conn).query_params["page"] do
        "2" ->
          Req.Test.json(conn, %{total_count: 101, artifacts: [%{id: 101, name: "comparison"}]})

        _ ->
          Req.Test.json(conn, %{
            total_count: 101,
            artifacts: for(id <- 1..100, do: %{id: id, name: "diff-#{id}"})
          })
      end
    end)

    assert {:ok, %{artifacts: artifacts}} =
             Actions.list_workflow_run_artifacts("NixOS", "nixpkgs", 123,
               plug: {Req.Test, __MODULE__}
             )

    assert Enum.map(artifacts, & &1.id) == Enum.to_list(1..101)
    assert %Artifact{name: "comparison"} = List.last(artifacts)
  end

  test "a later page failure does not return a partial artifact inventory" do
    Req.Test.stub(__MODULE__, fn conn ->
      case Plug.Conn.fetch_query_params(conn).query_params["page"] do
        "2" ->
          Plug.Conn.send_resp(conn, 503, "unavailable")

        _ ->
          Req.Test.json(conn, %{
            total_count: 101,
            artifacts: for(id <- 1..100, do: %{id: id, name: "diff-#{id}"})
          })
      end
    end)

    assert {:error, %Error{reason: :server_error}} =
             Actions.list_workflow_run_artifacts("NixOS", "nixpkgs", 123,
               plug: {Req.Test, __MODULE__}
             )
  end
end
