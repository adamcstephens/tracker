defmodule TrackerWeb.LensHookTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.Channel
  alias TrackerWeb.LensHook

  setup do
    suffix = System.unique_integer([:positive])

    stable =
      Channel.create!(%{
        name: "nixos-25.#{suffix}",
        display_name: "NixOS 25.#{suffix}",
        status: :active,
        is_stable: true
      })

    unstable =
      Channel.create!(%{
        name: "nixos-unstable-#{suffix}",
        display_name: "NixOS Unstable #{suffix}",
        status: :active,
        is_stable: false
      })

    %{stable: stable, unstable: unstable}
  end

  defp build_socket(opts \\ []) do
    connect_params = Keyword.get(opts, :connect_params, nil)
    transport_pid = if connect_params, do: self(), else: nil

    %Phoenix.LiveView.Socket{
      endpoint: TrackerWeb.Endpoint,
      transport_pid: transport_pid,
      assigns: %{__changed__: %{}},
      private: if(connect_params, do: %{connect_params: connect_params}, else: %{})
    }
  end

  describe "on_mount/4" do
    test "assigns default stable channel with no session or params", %{stable: stable} do
      socket = build_socket()
      {:cont, socket} = LensHook.on_mount(:default, %{}, %{}, socket)

      assert socket.assigns.lens.channel.name == stable.name
      assert socket.assigns.lens.revision == nil
      assert socket.assigns.lens.disabled? == false
    end

    test "uses session channel when present", %{unstable: unstable} do
      socket = build_socket()
      session = %{"lens_channel_name" => unstable.name}
      {:cont, socket} = LensHook.on_mount(:default, %{}, session, socket)

      assert socket.assigns.lens.channel.name == unstable.name
    end

    test "URL params override session", %{stable: stable, unstable: unstable} do
      socket = build_socket()
      params = %{"lens_channel" => unstable.name}
      session = %{"lens_channel_name" => stable.name}
      {:cont, socket} = LensHook.on_mount(:default, params, session, socket)

      assert socket.assigns.lens.channel.name == unstable.name
    end

    test "connect_params override session and URL params", %{stable: stable, unstable: unstable} do
      socket = build_socket(connect_params: %{"_lens_channel" => unstable.name})
      params = %{"lens_channel" => stable.name}
      session = %{"lens_channel_name" => stable.name}
      {:cont, socket} = LensHook.on_mount(:default, params, session, socket)

      assert socket.assigns.lens.channel.name == unstable.name
    end

    test "falls back to default for invalid session channel", %{stable: stable} do
      socket = build_socket()
      session = %{"lens_channel_name" => "nonexistent"}
      {:cont, socket} = LensHook.on_mount(:default, %{}, session, socket)

      assert socket.assigns.lens.channel.name == stable.name
    end
  end
end

defmodule TrackerWeb.LensHookNoChannelsTest do
  use Tracker.DataCase, async: true

  alias TrackerWeb.LensHook

  defp build_socket do
    %Phoenix.LiveView.Socket{
      endpoint: TrackerWeb.Endpoint,
      assigns: %{__changed__: %{}}
    }
  end

  test "assigns nil lens when no channels exist" do
    socket = build_socket()
    {:cont, socket} = LensHook.on_mount(:default, %{}, %{}, socket)

    assert socket.assigns.lens == nil
  end
end
