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
end
