defmodule GitHub.Actions do
  @moduledoc """
  GitHub Actions endpoints.
  """

  alias GitHub.Client

  defmodule Artifact do
    @moduledoc "A workflow run artifact."
    use TypedStruct

    typedstruct do
      field :id, integer()
      field :name, String.t()
      field :archive_download_url, String.t()
      field :expired, boolean()
    end
  end

  defmodule WorkflowRun do
    @moduledoc "A workflow run."
    use TypedStruct

    typedstruct do
      field :id, integer()
      field :name, String.t()
      field :status, String.t()
      field :conclusion, String.t()
      field :head_sha, String.t()
    end
  end

  @doc """
  Lists all artifacts for a workflow run, under `:artifacts`.
  Fetches pages of 100 artifacts and propagates errors without returning partial results.
  """
  @spec list_workflow_run_artifacts(String.t(), String.t(), integer(), keyword()) ::
          {:ok, %{artifacts: [Artifact.t()]}} | {:error, GitHub.Error.t()}
  def list_workflow_run_artifacts(owner, repo, run_id, opts \\ []) do
    url = "/repos/#{owner}/#{repo}/actions/runs/#{run_id}/artifacts"
    list_artifact_pages(url, opts, 1, [])
  end

  defp list_artifact_pages(url, opts, page, acc) do
    opts = Keyword.merge(opts, page: page, per_page: 100)

    with {:ok, json} <- Client.get(url, Client.to_request_opts(opts)) do
      artifacts = Map.fetch!(json, "artifacts")
      acc = Enum.reduce(artifacts, acc, fn item, acc -> [artifact(item) | acc] end)

      if length(artifacts) == 100 do
        list_artifact_pages(url, opts, page + 1, acc)
      else
        {:ok, %{artifacts: Enum.reverse(acc)}}
      end
    else
      {:error, _} = error -> error
    end
  end

  @doc """
  Lists workflow runs for a repository, under `:workflow_runs`. Supports
  `:head_sha` and `:per_page` params.
  """
  @spec list_workflow_runs_for_repo(String.t(), String.t(), keyword()) ::
          {:ok, %{workflow_runs: [WorkflowRun.t()]}} | {:error, GitHub.Error.t()}
  def list_workflow_runs_for_repo(owner, repo, opts \\ []) do
    url = "/repos/#{owner}/#{repo}/actions/runs"

    with {:ok, json} <- Client.get(url, Client.to_request_opts(opts)) do
      {:ok, %{workflow_runs: Enum.map(json["workflow_runs"] || [], &workflow_run/1)}}
    end
  end

  defp artifact(map) do
    %Artifact{
      id: map["id"],
      name: map["name"],
      archive_download_url: map["archive_download_url"],
      expired: map["expired"]
    }
  end

  defp workflow_run(map) do
    %WorkflowRun{
      id: map["id"],
      name: map["name"],
      status: map["status"],
      conclusion: map["conclusion"],
      head_sha: map["head_sha"]
    }
  end
end
