defmodule GitHub.Repos do
  @moduledoc """
  GitHub repository endpoints.
  """

  alias GitHub.Client

  defmodule Commit do
    @moduledoc "A commit, with its parent references."
    use TypedStruct

    defmodule Parent do
      @moduledoc "A parent commit reference."
      use TypedStruct

      typedstruct do
        field :sha, String.t()
      end
    end

    typedstruct do
      field :sha, String.t()
      field :parents, [Parent.t()], default: []
    end
  end

  @doc """
  Fetches a single commit by `ref` (SHA, branch, or tag).
  """
  @spec get_commit(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Commit.t()} | {:error, GitHub.Error.t()}
  def get_commit(owner, repo, ref, opts \\ []) do
    url = "/repos/#{owner}/#{repo}/commits/#{ref}"

    with {:ok, json} <- Client.get(url, Client.to_request_opts(opts)) do
      parents = Enum.map(json["parents"] || [], &%Commit.Parent{sha: &1["sha"]})
      {:ok, %Commit{sha: json["sha"], parents: parents}}
    end
  end

  @doc "Lists blob paths from a complete recursive Git tree."
  def list_tree_files(owner, repo, ref, opts \\ []) do
    opts = opts |> Keyword.put(:recursive, 1) |> Client.to_request_opts()

    with {:ok, json} <- Client.get("/repos/#{owner}/#{repo}/git/trees/#{ref}", opts) do
      tree_files(json)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp tree_files(%{"truncated" => true}), do: {:error, :truncated_tree}

  defp tree_files(%{"truncated" => false, "tree" => entries}) when is_list(entries) do
    if Enum.all?(entries, &valid_tree_entry?/1) do
      {:ok, for(%{"type" => "blob", "path" => path} <- entries, do: path)}
    else
      {:error, :invalid_tree}
    end
  end

  defp tree_files(_), do: {:error, :invalid_tree}

  defp valid_tree_entry?(%{"path" => path, "type" => type})
       when is_binary(path) and type in ["blob", "tree", "commit"],
       do: true

  defp valid_tree_entry?(_), do: false
end
