defmodule GitHub.ReposTest do
  use ExUnit.Case, async: true

  alias GitHub.Repos

  test "returns all blob paths beyond the Contents API directory limit" do
    files = for n <- 1..1_001, do: "members/user#{n}"

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        truncated: false,
        tree:
          [%{path: "members", type: "tree"}] ++
            Enum.map(files, &%{path: &1, type: "blob"})
      })
    end)

    assert {:ok, ^files} = list_files()
  end

  test "rejects truncated or malformed trees instead of returning a partial inventory" do
    for body <- [
          %{truncated: true, tree: [%{path: "members/alice", type: "blob"}]},
          %{tree: []},
          %{truncated: false, tree: nil},
          %{truncated: false, tree: [%{type: "blob"}]}
        ] do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, body) end)
      assert {:error, _reason} = list_files()
    end
  end

  test "propagates HTTP failure without returning an empty inventory" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
    assert {:error, %GitHub.Error{reason: :server_error}} = list_files()
  end

  defp list_files do
    Repos.list_tree_files("NixOS", "nixpkgs-committers", "main", plug: {Req.Test, __MODULE__})
  end
end
