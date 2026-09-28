defmodule Tracker.Ingestion.Steps.ExtractHydraPackagesTest do
  use Tracker.DataCase, async: false

  alias Tracker.GitServer
  alias Tracker.Ingestion.StepContext
  alias Tracker.Ingestion.Steps.ExtractHydraPackages
  alias Tracker.Nixpkgs.{Channel, ChannelRevision}

  setup do
    root = Path.join(System.tmp_dir!(), "hydra-selection-#{System.unique_integer([:positive])}")
    work = Path.join(root, "work")
    bare = Path.join(root, "bare.git")
    File.mkdir_p!(Path.join(work, "nixos"))
    git!(work, ["init", "-q"])
    git!(work, ["config", "user.email", "test@example.com"])
    git!(work, ["config", "commit.gpgsign", "false"])
    git!(work, ["config", "user.name", "Test"])

    first = commit!(work, "{ }: { nixpkgs = { hello = throw \"must not force\"; foo = null; }; }")
    second = commit!(work, "{ }: { nixpkgs = { bar = throw \"must not force\"; }; }")
    git!(root, ["clone", "-q", "--bare", work, bare])
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      state: %GitServer.State{path: bare, repo_url: work, ready: true},
      first: first,
      second: second
    }
  end

  test "extracts only attribute names from the exact revision without forcing values",
       %{state: %GitServer.State{} = state} = ctx do
    channel = channel!("nixos-test-small")
    first = revision!(channel, ctx.first, ~U[2026-01-01 00:00:00Z])
    second = revision!(channel, ctx.second, ~U[2026-01-02 00:00:00Z])

    assert :ok = ExtractHydraPackages.populate(first, channel, ctx.state)
    assert ChannelRevision.get_by_id!(first.id).hydra_package_attributes == ["foo", "hello"]
    assert :ok = ExtractHydraPackages.populate(second, channel, ctx.state)
    assert ChannelRevision.get_by_id!(second.id).hydra_package_attributes == ["bar"]

    assert :ok =
             ExtractHydraPackages.populate(
               ChannelRevision.get_by_id!(first.id),
               channel,
               %GitServer.State{state | ready: false}
             )

    assert ChannelRevision.get_by_id!(first.id).hydra_package_attributes == ["foo", "hello"]
  end

  test "empty extracted selection is persisted and reused",
       %{state: %GitServer.State{} = state} = ctx do
    channel = channel!("nixos-empty-small")
    revision = revision!(channel, ctx.first, ~U[2026-01-01 00:00:00Z])

    revision =
      ChannelRevision.record_hydra_package_attributes!(revision, %{hydra_package_attributes: []})

    assert :ok =
             ExtractHydraPackages.populate(revision, channel, %GitServer.State{
               state
               | ready: false
             })

    assert ChannelRevision.get_by_id!(revision.id).hydra_package_attributes == []
  end

  test "full channels are never extracted even if the source is unavailable",
       %{state: %GitServer.State{} = state} = ctx do
    channel = channel!("nixos-unstable")
    revision = revision!(channel, ctx.first, ~U[2026-01-01 00:00:00Z])

    assert :ok =
             ExtractHydraPackages.populate(revision, channel, %GitServer.State{
               state
               | ready: false
             })

    assert ChannelRevision.get_by_id!(revision.id).hydra_package_attributes == nil
  end

  test "backfill processes existing small revisions without ingesting packages",
       %{state: %GitServer.State{} = state} = ctx do
    channel = channel!("nixos-backfill-small")
    first = revision!(channel, ctx.first, ~U[2026-01-01 00:00:00Z])
    second = revision!(channel, ctx.second, ~U[2026-01-02 00:00:00Z])

    assert :ok = ExtractHydraPackages.backfill(channel.name, ctx.state)
    assert ChannelRevision.get_by_id!(first.id).hydra_package_attributes == ["foo", "hello"]
    assert ChannelRevision.get_by_id!(second.id).hydra_package_attributes == ["bar"]

    assert :ok =
             ExtractHydraPackages.backfill(channel.name, %GitServer.State{state | ready: false})
  end

  test "step dispatch persists selection for the current revision", ctx do
    channel = channel!("nixos-step-small")
    revision = revision!(channel, ctx.first, ~U[2026-01-01 00:00:00Z])

    assert :ok =
             ExtractHydraPackages.run(
               %StepContext{pipeline: nil, channel_revision: revision},
               ctx.state
             )

    assert ChannelRevision.get_by_id!(revision.id).hydra_package_attributes == ["foo", "hello"]
  end

  defp channel!(name),
    do: Channel.create!(%{name: name, display_name: name, status: :active, is_stable: false})

  defp revision!(channel, sha, released_at),
    do:
      ChannelRevision.create!(%{channel_id: channel.id, revision: sha, released_at: released_at})

  defp commit!(work, expression) do
    File.write!(Path.join(work, "nixos/release-small.nix"), expression)
    git!(work, ["add", "nixos/release-small.nix"])
    git!(work, ["commit", "-qm", "selection"])
    git!(work, ["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(directory, args) do
    {output, 0} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)
    output
  end
end
