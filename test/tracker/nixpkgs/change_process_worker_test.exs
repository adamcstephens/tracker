defmodule Tracker.Nixpkgs.ChangeProcessWorkerTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.ChangeProcessWorker
  alias Tracker.Nixpkgs.Package

  describe "upsert_change/1" do
    test "creates a Change record from a PR struct" do
      pr = pr_struct()

      {:ok, change} = ChangeProcessWorker.upsert_change(pr)

      assert change.number == 504_403
      assert change.title == "nixos/incus: add useACMEHost option"
      assert change.state == :merged
      assert change.author == "herbetom"
      assert change.author_github_id == 12345
      assert change.merged_by_github_id == 67890
      assert change.url == "https://github.com/NixOS/nixpkgs/pull/504403"
      assert change.base_ref == "master"
      assert change.labels == ["6.topic: nixos", "backport release-25.11"]
      assert change.merge_commit_sha == "f2b75e04afe69bf02253b3895390045d47f9fbc0"
      assert change.processing_status == :pending
    end

    test "upserts on repeated calls" do
      pr = pr_struct()

      {:ok, change1} = ChangeProcessWorker.upsert_change(pr)
      {:ok, change2} = ChangeProcessWorker.upsert_change(%{pr | title: "updated title"})

      assert change1.id == change2.id
      assert change2.title == "updated title"
    end
  end

  describe "link_packages/2" do
    test "links change to existing packages from attrdiff with types" do
      Package.bulk_upsert_all([
        %{attribute: "nixos-install-tools"},
        %{attribute: "curl"}
      ])

      {:ok, change} = ChangeProcessWorker.upsert_change(pr_struct())

      attrdiff = %{
        "added" => ["curl"],
        "changed" => ["nixos-install-tools"],
        "removed" => []
      }

      {:ok, linked} = ChangeProcessWorker.link_packages(change, attrdiff)

      assert linked == 2

      change = Ash.load!(change, [:packages, :change_packages])
      attrs = Enum.map(change.packages, & &1.attribute) |> Enum.sort()
      assert attrs == ["curl", "nixos-install-tools"]

      types = change.change_packages |> Enum.sort_by(& &1.package_id) |> Enum.map(& &1.type)
      assert :added in types
      assert :changed in types
    end

    test "skips attributes not found in packages table" do
      Package.bulk_upsert_all([%{attribute: "curl"}])

      {:ok, change} = ChangeProcessWorker.upsert_change(pr_struct())

      attrdiff = %{
        "added" => [],
        "changed" => ["curl", "nonexistent-package"],
        "removed" => []
      }

      {:ok, linked} = ChangeProcessWorker.link_packages(change, attrdiff)

      assert linked == 1
    end

    test "handles empty attrdiff" do
      {:ok, change} = ChangeProcessWorker.upsert_change(pr_struct())

      attrdiff = %{"added" => [], "changed" => [], "removed" => []}

      {:ok, linked} = ChangeProcessWorker.link_packages(change, attrdiff)

      assert linked == 0
    end
  end

  describe "set_processing_status/2" do
    test "sets status to :processed" do
      {:ok, change} = ChangeProcessWorker.upsert_change(pr_struct())

      updated = ChangeProcessWorker.set_processing_status(change, :processed)

      assert updated.processing_status == :processed
    end

    test "sets status to :artifact_expired" do
      {:ok, change} = ChangeProcessWorker.upsert_change(pr_struct())

      updated = ChangeProcessWorker.set_processing_status(change, :artifact_expired)

      assert updated.processing_status == :artifact_expired
    end

    test "sets status to :no_workflow_run" do
      {:ok, change} = ChangeProcessWorker.upsert_change(pr_struct())

      updated = ChangeProcessWorker.set_processing_status(change, :no_workflow_run)

      assert updated.processing_status == :no_workflow_run
    end

    test "sets status to :no_comparison_artifact" do
      {:ok, change} = ChangeProcessWorker.upsert_change(pr_struct())

      updated = ChangeProcessWorker.set_processing_status(change, :no_comparison_artifact)

      assert updated.processing_status == :no_comparison_artifact
    end

    test "sets status to :failed" do
      {:ok, change} = ChangeProcessWorker.upsert_change(pr_struct())

      updated = ChangeProcessWorker.set_processing_status(change, :failed)

      assert updated.processing_status == :failed
    end
  end

  describe "parse_pr_payload/1" do
    test "extracts change fields from a PR struct" do
      pr = pr_struct()
      parsed = ChangeProcessWorker.parse_pr_payload(pr)

      assert parsed.number == 504_403
      assert parsed.title == "nixos/incus: add useACMEHost option"
      assert parsed.state == :merged
      assert parsed.author == "herbetom"
      assert parsed.author_github_id == 12345
      assert parsed.merged_by_github_id == 67890
      assert parsed.base_ref == "master"
      assert parsed.merge_commit_sha == "f2b75e04afe69bf02253b3895390045d47f9fbc0"
    end

    test "sets state to :closed when not merged" do
      pr = %{pr_struct() | merged: false, merged_at: nil, merged_by: nil}
      parsed = ChangeProcessWorker.parse_pr_payload(pr)

      assert parsed.state == :closed
    end

    test "sets state to :open when state is open" do
      pr = %{pr_struct() | state: "open", merged: false, merged_at: nil, merged_by: nil}
      parsed = ChangeProcessWorker.parse_pr_payload(pr)

      assert parsed.state == :open
    end
  end

  defp pr_struct do
    %GitHub.PullRequest{
      number: 504_403,
      title: "nixos/incus: add useACMEHost option",
      state: "closed",
      merged: true,
      user: %GitHub.User{login: "herbetom", id: 12345},
      merged_by: %GitHub.User{login: "adamcstephens", id: 67890},
      html_url: "https://github.com/NixOS/nixpkgs/pull/504403",
      base: %GitHub.PullRequest.Base{ref: "master"},
      labels: [
        %GitHub.PullRequest.Labels{name: "6.topic: nixos"},
        %GitHub.PullRequest.Labels{name: "backport release-25.11"}
      ],
      merge_commit_sha: "f2b75e04afe69bf02253b3895390045d47f9fbc0",
      created_at: ~U[2026-03-28 16:15:06Z],
      merged_at: ~U[2026-03-31 01:57:58Z]
    }
  end
end
