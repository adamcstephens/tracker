defmodule TrackerWeb.LensTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.Channel
  alias TrackerWeb.Lens

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

  describe "resolve/2" do
    test "returns default stable channel when given nil", %{stable: stable} do
      lens = Lens.resolve(nil, nil)
      assert lens.channel.name == stable.name
      assert lens.revision == nil
      assert lens.disabled? == false
    end

    test "resolves a named channel", %{unstable: unstable} do
      lens = Lens.resolve(unstable.name, nil)
      assert lens.channel.name == unstable.name
    end

    test "falls back to default stable for unknown channel", %{stable: stable} do
      lens = Lens.resolve("nonexistent", nil)
      assert lens.channel.name == stable.name
    end

    test "falls back to default stable for retired channel" do
      suffix = System.unique_integer([:positive])

      retired =
        Channel.create!(%{
          name: "nixos-24.#{suffix}",
          display_name: "NixOS 24.#{suffix}",
          status: :retired,
          is_stable: true
        })

      lens = Lens.resolve(retired.name, nil)
      assert lens.channel.name == retired.name
    end

    test "ignores empty string channel name", %{stable: stable} do
      lens = Lens.resolve("", nil)
      assert lens.channel.name == stable.name
    end

    test "resolves 'all' to all-channels lens with default stable fallback", %{stable: stable} do
      lens = Lens.resolve("all", nil)
      assert lens.all? == true
      assert lens.channel.name == stable.name
      assert lens.revision == nil
    end

    test "resolves 'all' ignores revision", %{stable: stable} do
      lens = Lens.resolve("all", "abc1234")
      assert lens.all? == true
      assert lens.channel.name == stable.name
      assert lens.revision == nil
    end
  end

  describe "cookie_value/1 and from_cookie/1" do
    test "round-trips channel only", %{unstable: unstable} do
      lens = Lens.resolve(unstable.name, nil)
      value = Lens.cookie_value(lens)
      {name, rev} = Lens.from_cookie(value)
      assert name == unstable.name
      assert rev == nil
    end

    test "round-trips channel and revision" do
      value = "some-channel:abc123def"
      {name, rev} = Lens.from_cookie(value)
      assert name == "some-channel"
      assert rev == "abc123def"
    end

    test "handles nil gracefully" do
      assert {nil, nil} = Lens.from_cookie(nil)
    end

    test "handles empty string gracefully" do
      assert {nil, nil} = Lens.from_cookie("")
    end

    test "handles garbage gracefully" do
      {name, rev} = Lens.from_cookie("just-a-name")
      assert name == "just-a-name"
      assert rev == nil
    end

    test "cookie round-trips 'all' lens", %{stable: stable} do
      lens = Lens.resolve("all", nil)
      assert Lens.cookie_value(lens) == "all"

      {name, rev} = Lens.from_cookie("all")
      assert name == "all"
      assert rev == nil

      round_tripped = Lens.resolve(name, rev)
      assert round_tripped.all? == true
      assert round_tripped.channel.name == stable.name
    end
  end

  describe "channel_id/1" do
    test "returns nil for nil lens" do
      assert Lens.channel_id(nil) == nil
    end

    test "returns nil for all-channels lens" do
      lens = Lens.resolve("all", nil)
      assert Lens.channel_id(lens) == nil
    end

    test "returns channel id for specific channel lens", %{unstable: unstable} do
      lens = Lens.resolve(unstable.name, nil)
      assert Lens.channel_id(lens) == unstable.id
    end
  end

  describe "sign_cookie/1 and verify_cookie/1" do
    test "round-trips through signing", %{unstable: unstable} do
      lens = Lens.resolve(unstable.name, nil)
      signed = Lens.sign_cookie(lens)
      assert is_binary(signed)

      {:ok, value} = Lens.verify_cookie(signed)
      assert value == unstable.name
    end

    test "verify rejects tampered tokens" do
      assert :error = Lens.verify_cookie("tampered-value")
    end
  end
end
