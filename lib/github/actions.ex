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
  Lists artifacts for a workflow run, under `:artifacts`.
  """
  @spec list_workflow_run_artifacts(String.t(), String.t(), integer(), keyword()) ::
          {:ok, %{artifacts: [Artifact.t()]}} | {:error, GitHub.Error.t()}
  def list_workflow_run_artifacts(owner, repo, run_id, opts \\ []) do
    url = "/repos/#{owner}/#{repo}/actions/runs/#{run_id}/artifacts"

    with {:ok, json} <- Client.get(url, Client.to_request_opts(opts)) do
      {:ok, %{artifacts: Enum.map(json["artifacts"] || [], &artifact/1)}}
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
