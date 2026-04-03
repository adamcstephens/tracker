defmodule Tracker.Nixpkgs.ChannelRevisionTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.ChannelRevision

  describe "distinct_nixos_channels/0" do
    test "returns only nixos-* channels" do
      for channel <- ["nixos-unstable", "nixos-24.11", "nixpkgs-unstable"] do
        ChannelRevision.create!(%{
          channel: channel,
          revision: "abc#{channel}",
          released_at: "2026-04-01T10:00:00Z"
        })
      end

      channels =
        ChannelRevision.distinct_nixos_channels!()
        |> Enum.map(& &1.channel)

      assert "nixos-unstable" in channels
      assert "nixos-24.11" in channels
      refute "nixpkgs-unstable" in channels
    end

    test "returns channels sorted alphabetically" do
      for channel <- ["nixos-unstable", "nixos-24.05", "nixos-24.11"] do
        ChannelRevision.create!(%{
          channel: channel,
          revision: "sort#{channel}",
          released_at: "2026-04-01T10:00:00Z"
        })
      end

      channels =
        ChannelRevision.distinct_nixos_channels!()
        |> Enum.map(& &1.channel)
        |> Enum.filter(&String.starts_with?(&1, "nixos-24"))

      assert channels == ["nixos-24.05", "nixos-24.11"]
    end
  end
end
