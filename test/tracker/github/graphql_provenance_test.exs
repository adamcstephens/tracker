defmodule Tracker.GitHub.GraphQLProvenanceTest do
  use ExUnit.Case, async: true

  alias GitHub.Error
  alias Tracker.GitHub.GraphQL
  alias Tracker.GitHub.RateLimitCache

  defp response(repository, rate_limit \\ nil) do
    {:ok,
     %Req.Response{
       status: 200,
       body: %{"data" => %{"repository" => repository, "rateLimit" => rate_limit}}
     }}
  end

  defp connection(nodes, cursor \\ nil) do
    %{
      "nodes" => nodes,
      "pageInfo" => %{"hasNextPage" => cursor != nil, "endCursor" => cursor}
    }
  end

  defp associated(number, repo \\ "NixOS/nixpkgs") do
    %{"number" => number, "repository" => %{"nameWithOwner" => repo}}
  end

  defp opts(request_fun), do: [token: "test-token", request_fun: request_fun]

  describe "fetch_pr_commit_messages/2" do
    test "fetches full messages across all commit pages in order" do
      request_fun = fn request ->
        assert request[:method] == :post
        assert request[:retry] == false
        assert request[:json].query =~ "message"
        variables = request[:json].variables
        assert variables["owner"] == "NixOS"
        assert variables["name"] == "nixpkgs"
        assert variables["number"] == 123

        commits =
          case variables["after"] do
            nil ->
              connection([%{"commit" => %{"message" => "subject\n\nbody"}}], "page2")

            "page2" ->
              connection([%{"commit" => %{"message" => "(cherry picked from commit abc)"}}])
          end

        response(%{"pullRequest" => %{"commits" => commits}})
      end

      assert {:ok, ["subject\n\nbody", "(cherry picked from commit abc)"]} =
               GraphQL.fetch_pr_commit_messages(123, opts(request_fun))
    end

    test "returns an empty list for a pull request with no commits" do
      request_fun = fn _ -> response(%{"pullRequest" => %{"commits" => connection([])}}) end
      assert {:ok, []} = GraphQL.fetch_pr_commit_messages(123, opts(request_fun))
    end

    test "rejects partial GraphQL data rather than treating it as complete evidence" do
      errors = [%{"type" => "INTERNAL", "message" => "unavailable"}]

      request_fun = fn _ ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "errors" => errors,
             "data" => %{"repository" => %{"pullRequest" => %{"commits" => connection([])}}}
           }
         }}
      end

      assert {:error, {:graphql_errors, ^errors}} =
               GraphQL.fetch_pr_commit_messages(123, opts(request_fun))
    end

    test "does not silently truncate a page with a missing or repeated next cursor" do
      for cursor <- [nil, "same"] do
        request_fun = fn _request ->
          commits = %{
            "nodes" => [],
            "pageInfo" => %{"hasNextPage" => true, "endCursor" => cursor}
          }

          response(%{"pullRequest" => %{"commits" => commits}})
        end

        assert {:error, %Error{}} = GraphQL.fetch_pr_commit_messages(123, opts(request_fun))
      end
    end

    test "missing pull requests and malformed messages remain errors" do
      for repository <- [
            %{"pullRequest" => nil},
            %{"pullRequest" => %{"commits" => connection([%{"commit" => nil}])}}
          ] do
        assert {:error, %Error{}} =
                 GraphQL.fetch_pr_commit_messages(123, opts(fn _ -> response(repository) end))
      end
    end

    test "propagates an error on a later page without returning partial messages" do
      request_fun = fn request ->
        case request[:json].variables["after"] do
          nil -> response(%{"pullRequest" => %{"commits" => connection([], "next")}})
          "next" -> {:error, :closed}
        end
      end

      assert {:error, %Error{source: :closed}} =
               GraphQL.fetch_pr_commit_messages(123, opts(request_fun))
    end
  end

  describe "fetch_commit_pr_numbers/2" do
    test "preserves every same-repository association and paginates ambiguity" do
      request_fun = fn request ->
        query = request[:json].query
        variables = request[:json].variables
        assert query =~ "associatedPullRequests"
        assert query =~ "repository { nameWithOwner }"

        case variables["after0"] do
          nil ->
            assert variables["sha0"] == "abc"
            assert variables["sha1"] == "def"

            response(%{
              "c0" => %{
                "associatedPullRequests" =>
                  connection([associated(10), associated(999, "someone/fork")], "next")
              },
              "c1" => %{"associatedPullRequests" => connection([])}
            })

          "next" ->
            assert variables["sha0"] == "abc"
            refute Map.has_key?(variables, "sha1")

            response(%{
              "c0" => %{
                "associatedPullRequests" =>
                  connection([associated(10), associated(11, "nixos/Nixpkgs")])
              }
            })
        end
      end

      assert {:ok, %{"abc" => [10, 11], "def" => []}} =
               GraphQL.fetch_commit_pr_numbers(["abc", "def", "abc"], opts(request_fun))
    end

    test "batches more than 25 distinct commits" do
      request_fun = fn request ->
        variables = request[:json].variables
        shas = for {"sha" <> index, sha} <- variables, do: {index, sha}
        assert length(shas) <= 25
        send(self(), {:batch_size, length(shas)})

        repository =
          Map.new(shas, fn {index, _sha} ->
            {"c" <> index, %{"associatedPullRequests" => connection([associated(42)])}}
          end)

        response(repository)
      end

      shas = Enum.map(1..26, &Integer.to_string(&1, 16))
      assert {:ok, result} = GraphQL.fetch_commit_pr_numbers(shas, opts(request_fun))
      assert result == Map.new(shas, &{&1, [42]})
      assert_receive {:batch_size, 25}
      assert_receive {:batch_size, 1}
      refute_receive {:batch_size, _}
    end

    test "empty input does not fetch credentials or make requests" do
      assert {:ok, %{}} = GraphQL.fetch_commit_pr_numbers([])
    end

    test "supports an explicit repository and filters other repositories" do
      request_fun = fn request ->
        assert request[:json].variables["owner"] == "another"
        assert request[:json].variables["name"] == "repo"

        response(%{
          "c0" => %{
            "associatedPullRequests" => connection([associated(1), associated(2, "another/repo")])
          }
        })
      end

      assert {:ok, %{"abc" => [2]}} =
               GraphQL.fetch_commit_pr_numbers(
                 ["abc"],
                 opts(request_fun) ++ [repo: "another/repo"]
               )
    end

    test "missing commits, malformed connections, and unknown repositories remain errors" do
      for repository <- [
            %{"c0" => nil},
            %{"c0" => %{"associatedPullRequests" => nil}},
            %{"c0" => %{"associatedPullRequests" => connection([%{"number" => 1}])}}
          ] do
        assert {:error, %Error{}} =
                 GraphQL.fetch_commit_pr_numbers(["abc"], opts(fn _ -> response(repository) end))
      end
    end

    test "uses GraphQL rate-limit tracking on each provenance page" do
      table = :"provenance_limit_#{System.unique_integer([:positive])}"
      RateLimitCache.new(table)
      on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
      reset = DateTime.add(DateTime.utc_now(), 1800, :second) |> DateTime.to_iso8601()

      request_fun = fn _ ->
        response(%{"c0" => %{"associatedPullRequests" => connection([])}}, %{
          "remaining" => 50,
          "resetAt" => reset
        })
      end

      assert {:ok, _} =
               GraphQL.fetch_commit_pr_numbers(
                 ["abc"],
                 opts(request_fun) ++ [rate_limit_table: table]
               )

      assert {:limited, seconds} = RateLimitCache.check(:graphql, table)
      assert seconds > 0
    end

    test "HTTP and GraphQL rate limiting remain distinguishable from absent associations" do
      for reply <- [
            {:ok, %Req.Response{status: 429}},
            {:ok, %Req.Response{status: 403}},
            {:ok,
             %Req.Response{
               status: 200,
               body: %{"errors" => [%{"type" => "RATE_LIMITED"}]}
             }}
          ] do
        assert {:error, %Error{reason: :rate_limited}} =
                 GraphQL.fetch_commit_pr_numbers(["abc"], opts(fn _ -> reply end))
      end
    end

    test "supports the existing Req plug injection" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"variables" => %{"sha0" => "abc"}} = Jason.decode!(raw)
        assert Plug.Conn.get_req_header(conn, "authorization") == ["bearer test-token"]

        {:ok, result} =
          response(%{"c0" => %{"associatedPullRequests" => connection([associated(9)])}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(result.body))
      end)

      assert {:ok, %{"abc" => [9]}} =
               GraphQL.fetch_commit_pr_numbers(["abc"],
                 token: "test-token",
                 plug: {Req.Test, __MODULE__}
               )
    end
  end
end
