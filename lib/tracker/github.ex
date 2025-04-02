defmodule Tracker.GitHub do
  def test() do
    app = GitHub.app(:tracker)

    {:ok, %{token: token}} =
      GitHub.Apps.create_installation_access_token(63_750_441, %{}, auth: app)

    # TODO: get the workflows from a PR

    {:ok, wfa} =
      GitHub.Actions.list_workflow_run_artifacts("nixos", "nixpkgs", 14_209_233_829, auth: token)

    artifact = wfa.artifacts |> Enum.filter(&(&1.name == "comparison")) |> List.first()

    {:ok, resp} =
      Req.get(artifact.archive_download_url, headers: %{authorization: "bearer #{token}"})

    # extracts to disk
    :zip.extract(resp.body)
    # {:ok, [~c"changed-paths.json", ~c"maintainers.json", ~c"step-summary.md"]}

    File.read!("changed-paths.json") |> Jason.decode!()
  end
end
