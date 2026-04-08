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
end
