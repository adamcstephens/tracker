defmodule Tracker.Nixpkgs.HydraStatusFetcherTest do
  use Tracker.DataCase, async: true

  alias Tracker.Hydra.Client.BuildFailure
  alias Tracker.Hydra.Client.ChannelStatus
  alias Tracker.Nixpkgs.Channel
  alias Tracker.Nixpkgs.HydraStatusFetcher

  defp build_failure(channel, attrs \\ %{}) do
    Map.merge(
      %BuildFailure{
        channel: channel,
        failed?: false,
        current?: true,
        project: "nixos",
        jobset: "release-x",
        exported_job: "tested"
      },
      attrs
    )
  end

  defp channel_status(channel, attrs \\ %{}) do
    Map.merge(
      %ChannelStatus{
        channel: channel,
        status: :rolling,
        revision: "abc",
        variant: "primary",
        current?: true
      },
      attrs
    )
  end

  describe "run/1" do
    test "upserts hydra fields onto matched channels" do
      channel =
        Channel.create!(%{
          name: "nixpkgs-unstable-#{System.unique_integer([:positive])}",
          display_name: "Nixpkgs Unstable",
          status: :active,
          is_stable: false
        })

      fetch = fn ->
        {:ok, [channel_status(channel.name)],
         [
           build_failure(channel.name, %{
             failed?: true,
             project: "nixpkgs",
             jobset: "unstable",
             exported_job: "unstable"
           })
         ]}
      end

      assert {:ok, %{updated: 1, skipped: 0}} = HydraStatusFetcher.run(fetch: fetch)

      {:ok, loaded} = Channel.by_name(channel.name, load: [:build_problem?])
      assert loaded.hydra_build_failed? == true
      assert loaded.hydra_project == "nixpkgs"
      assert loaded.hydra_jobset == "unstable"
      assert loaded.hydra_exported_job == "unstable"
      assert %DateTime{} = loaded.hydra_checked_at
      assert loaded.build_problem? == true
    end

    test "skips channels not present in our database" do
      fetch = fn ->
        {:ok, [channel_status("unknown-channel")], [build_failure("unknown-channel")]}
      end

      assert {:ok, %{updated: 0, skipped: 1}} = HydraStatusFetcher.run(fetch: fetch)
    end

    test "leaves channels untouched when prometheus reports no series for them" do
      channel =
        Channel.create!(%{
          name: "nixos-orphan-#{System.unique_integer([:positive])}",
          display_name: "Orphan",
          status: :active,
          is_stable: false
        })

      fetch = fn -> {:ok, [], []} end

      assert {:ok, %{updated: 0, skipped: 0}} = HydraStatusFetcher.run(fetch: fetch)

      {:ok, loaded} = Channel.by_name(channel.name)
      assert is_nil(loaded.hydra_build_failed?)
    end

    test "returns an error if either client call fails" do
      fetch = fn -> {:error, :boom} end
      assert {:error, :boom} = HydraStatusFetcher.run(fetch: fetch)
    end

    test "skips the update when fetched values match stored attrs" do
      channel =
        Channel.create!(%{
          name: "nixos-noop-#{System.unique_integer([:positive])}",
          display_name: "NoOp",
          status: :active,
          is_stable: false
        })

      {:ok, _} =
        Channel.update_hydra_status(channel, %{
          hydra_build_failed?: true,
          hydra_project: "nixpkgs",
          hydra_jobset: "unstable",
          hydra_exported_job: "tested"
        })

      {:ok, after_first} = Channel.by_name(channel.name)
      first_checked_at = after_first.hydra_checked_at

      Phoenix.PubSub.subscribe(Tracker.PubSub, "channels:hydra_status_updated")

      fetch = fn ->
        {:ok, [channel_status(channel.name)],
         [
           build_failure(channel.name, %{
             failed?: true,
             project: "nixpkgs",
             jobset: "unstable",
             exported_job: "tested"
           })
         ]}
      end

      assert {:ok, %{updated: 0, skipped: 1}} = HydraStatusFetcher.run(fetch: fetch)

      refute_receive %Ash.Notifier.Notification{resource: Channel}, 50

      {:ok, after_second} = Channel.by_name(channel.name)
      assert after_second.hydra_checked_at == first_checked_at
    end
  end
end
