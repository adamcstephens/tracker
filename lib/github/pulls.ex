defmodule GitHub.Pulls do
  @moduledoc """
  GitHub pull request endpoints.
  """

  alias GitHub.Client

  defmodule File do
    @moduledoc "A file changed in a pull request."
    use TypedStruct

    typedstruct do
      field :filename, String.t()
      field :status, String.t()
      field :additions, integer()
      field :deletions, integer()
      field :changes, integer()
    end
  end

  @doc """
  Lists files for a pull request. Supports `:per_page` and `:page` params.
  """
  @spec list_files(String.t(), String.t(), integer(), keyword()) ::
          {:ok, [File.t()]} | {:error, GitHub.Error.t()}
  def list_files(owner, repo, number, opts \\ []) do
    url = "/repos/#{owner}/#{repo}/pulls/#{number}/files"

    with {:ok, json} when is_list(json) <- Client.get(url, Client.to_request_opts(opts)) do
      {:ok, Enum.map(json, &file/1)}
    end
  end

  defp file(map) do
    %File{
      filename: map["filename"],
      status: map["status"],
      additions: map["additions"],
      deletions: map["deletions"],
      changes: map["changes"]
    }
  end
end
