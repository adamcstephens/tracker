defmodule TrackerWeb.LensHandlersTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.Channel
  alias TrackerWeb.LensHandlers

  setup do
    suffix = System.unique_integer([:positive])

    stable =
      Channel.create!(%{
        name: "nixos-25.#{suffix}",
        display_name: "NixOS 25.#{suffix}",
        branch: "release-25.#{suffix}",
        status: :active,
        is_stable: true
      })

    unstable =
      Channel.create!(%{
        name: "nixos-unstable-#{suffix}",
        display_name: "NixOS Unstable #{suffix}",
        branch: "nixos-unstable-#{suffix}",
        status: :active,
        is_stable: false
      })

    %{stable: stable, unstable: unstable}
  end

  defp build_socket do
    %Phoenix.LiveView.Socket{
      endpoint: TrackerWeb.Endpoint,
      assigns: %{__changed__: %{}},
      private: %{live_temp: %{}}
    }
  end

  test "handle_lens_change updates lens assign", %{unstable: unstable} do
    socket = build_socket()
    socket = LensHandlers.handle_lens_change(socket, unstable.name, "")

    assert socket.assigns.lens.channel.name == unstable.name
    assert socket.assigns.lens.revision == nil
  end

  test "handle_lens_change falls back to default for unknown channel", %{stable: stable} do
    socket = build_socket()
    socket = LensHandlers.handle_lens_change(socket, "nonexistent", "")

    assert socket.assigns.lens.channel.name == stable.name
  end

  test "set_lens_cookie event includes lens_channel for sessionStorage", %{unstable: unstable} do
    socket = build_socket()
    socket = LensHandlers.handle_lens_change(socket, unstable.name, "")

    events = socket.private.live_temp[:push_events]

    assert [["set_lens_cookie", payload | _]] = events
    assert payload.lens_channel == unstable.name
    assert payload.lens_rev == nil
  end

  test "set_lens_cookie event includes lens_rev when revision is set", %{unstable: unstable} do
    rev_hash = "abc1234"

    _cr =
      Tracker.Nixpkgs.ChannelRevision
      |> Ash.Changeset.for_create(:create, %{
        channel_id: unstable.id,
        revision: rev_hash,
        released_at: ~U[2025-06-01 00:00:00Z]
      })
      |> Ash.create!()

    socket = build_socket()
    socket = LensHandlers.handle_lens_change(socket, unstable.name, rev_hash)

    events = socket.private.live_temp[:push_events]

    assert [["set_lens_cookie", payload | _]] = events
    assert payload.lens_channel == unstable.name
    assert payload.lens_rev == rev_hash
  end

  test "set_lens_cookie event uses 'all' as lens_channel for all-channels lens" do
    socket = build_socket()
    socket = LensHandlers.handle_lens_change(socket, "all", "")

    events = socket.private.live_temp[:push_events]

    assert [["set_lens_cookie", payload | _]] = events
    assert payload.lens_channel == "all"
    assert payload.lens_rev == nil
  end
end
