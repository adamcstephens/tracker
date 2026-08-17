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

  describe "default channel fallback" do
    test "picks the newest nixos channel when no stable release is active", %{stable: stable} do
      suffix = System.unique_integer([:positive])
      Channel.update_status!(stable, %{status: :retired})

      Channel.create!(%{
        name: "nixos-unstable-a#{suffix}",
        display_name: "Older",
        status: :active,
        is_stable: false
      })

      newest =
        Channel.create!(%{
          name: "nixos-unstable-z#{suffix}",
          display_name: "Newest",
          status: :active,
          is_stable: false
        })

      assert Lens.resolve(nil, nil).channel.name == newest.name
    end

    test "skips retired channels when falling back", %{stable: stable, unstable: unstable} do
      suffix = System.unique_integer([:positive])
      Channel.update_status!(stable, %{status: :retired})

      Channel.create!(%{
        name: "nixos-zzz#{suffix}",
        display_name: "Retired",
        status: :retired,
        is_stable: false
      })

      assert Lens.resolve(nil, nil).channel.name == unstable.name
    end
  end

  describe "from_params/1" do
    test "reads the lens from URL params", %{unstable: unstable} do
      lens = Lens.from_params(%{"channel" => unstable.name})

      assert lens.channel.name == unstable.name
    end

    test "reads a pinned revision from URL params", %{unstable: unstable} do
      revision =
        Tracker.Nixpkgs.ChannelRevision.create!(%{
          channel_id: unstable.id,
          revision: "abc1234567890",
          released_at: ~U[2026-01-01 00:00:00Z]
        })

      lens = Lens.from_params(%{"channel" => unstable.name, "rev" => revision.revision})

      assert lens.revision.revision == revision.revision
    end

    test "params stating no channel state no lens" do
      assert Lens.from_params(%{}) == nil
    end
  end

  describe "canonical/1" do
    test "serializes a channel-only lens", %{unstable: unstable} do
      assert Lens.canonical(Lens.resolve(unstable.name, nil)) == {unstable.name, nil}
    end

    test "serializes a pinned lens", %{unstable: unstable} do
      revision =
        Tracker.Nixpkgs.ChannelRevision.create!(%{
          channel_id: unstable.id,
          revision: "abc1234567890",
          released_at: ~U[2026-01-01 00:00:00Z]
        })

      lens = Lens.resolve(unstable.name, revision.revision)

      assert Lens.canonical(lens) == {unstable.name, revision.revision}
    end

    test "serializes the all-channels lens" do
      assert Lens.canonical(Lens.resolve("all", nil)) == {"all", nil}
    end

    test "serializes no lens" do
      assert Lens.canonical(nil) == {nil, nil}
    end
  end

  describe "decorate/1" do
    setup %{unstable: unstable} do
      on_exit(fn -> Lens.put_current(nil) end)

      Lens.put_current(Lens.resolve(unstable.name, nil))

      :ok
    end

    test "puts the lens in force on a local path", %{unstable: unstable} do
      assert Lens.decorate("/packages") == "/packages?channel=#{unstable.name}"
    end

    test "keeps the other query params", %{unstable: unstable} do
      assert Lens.decorate("/packages?search=hello") ==
               "/packages?channel=#{unstable.name}&search=hello"
    end

    test "leaves a path that states its own channel alone" do
      assert Lens.decorate("/options?channel=nixos-pinned&rev=abc") ==
               "/options?channel=nixos-pinned&rev=abc"
    end

    test "leaves external targets alone" do
      assert Lens.decorate("https://github.com/NixOS/nixpkgs") ==
               "https://github.com/NixOS/nixpkgs"

      assert Lens.decorate("//cdn.example.com/thing") == "//cdn.example.com/thing"
      assert Lens.decorate("mailto:nobody@example.com") == "mailto:nobody@example.com"
      assert Lens.decorate("#main") == "#main"
    end

    test "leaves static assets alone" do
      assert Lens.decorate("/images/logo.png") == "/images/logo.png"
      assert Lens.decorate("/robots.txt") == "/robots.txt"
    end

    test "leaves non-paths alone" do
      assert Lens.decorate(nil) == nil
    end

    test "does nothing with no lens in force" do
      Lens.put_current(nil)

      assert Lens.decorate("/packages") == "/packages"
    end
  end

  describe "path_for/3" do
    test "sets the lens param on a bare path" do
      assert Lens.path_for("/packages", "nixos-unstable") ==
               "/packages?channel=nixos-unstable"
    end

    test "keeps the other query params" do
      params =
        "/changes?in_channel=1&page=2"
        |> Lens.path_for("nixos-unstable")
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert params == %{
               "in_channel" => "1",
               "page" => "2",
               "channel" => "nixos-unstable"
             }
    end

    test "drops a previously pinned revision" do
      assert Lens.path_for("/packages?channel=old&rev=deadbeef", "nixos-unstable") ==
               "/packages?channel=nixos-unstable"
    end

    test "carries a revision when one is given" do
      assert Lens.path_for("/packages", "nixos-unstable", "deadbeef") ==
               "/packages?channel=nixos-unstable&rev=deadbeef"
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
