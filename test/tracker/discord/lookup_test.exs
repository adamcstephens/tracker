defmodule Tracker.Discord.LookupTest do
  use Tracker.DataCase, async: true

  alias Tracker.Discord.Lookup
  alias Tracker.Fixtures

  setup do
    channel = Fixtures.channel!("nixos-unstable")

    revision =
      Fixtures.channel_revision!(channel, %{
        revision: "abc123456789",
        released_at: ~U[2026-08-23 12:00:00Z]
      })

    %{channel: channel, revision: revision}
  end

  test "returns package metadata at the default channel revision", %{revision: revision} do
    package = Fixtures.package!("hello")

    Fixtures.apply_package_revision!(revision, [
      {package,
       %{
         version: "2.12.1",
         description: "A program that produces a familiar greeting.",
         broken: true
       }}
    ])

    assert {:ok, %Lookup.Package{attribute: "hello", version: "2.12.1", broken: true} = result} =
             Lookup.package("hello")

    assert result.channel == "nixos-unstable"
    assert result.revision == "abc123456789"

    assert result.url ==
             TrackerWeb.Endpoint.url() <>
               "/packages/hello?channel=nixos-unstable&rev=abc123456789"
  end

  test "returns option metadata at the default channel revision", %{revision: revision} do
    option = Fixtures.option!("services.nginx.enable")

    Fixtures.apply_option_revision!(revision, [
      {option, %{type: "boolean", description: "Enable nginx.", read_only: true}}
    ])

    assert {:ok,
            %Lookup.Option{
              name: "services.nginx.enable",
              type: "boolean",
              description: "Enable nginx.",
              read_only: true,
              channel: "nixos-unstable",
              revision: "abc123456789"
            }} = Lookup.option("services.nginx.enable")
  end

  test "rejects an unavailable channel" do
    assert {:error, %Lookup.Error{reason: :unknown_channel, channel: "nixos-99.99"}} =
             Lookup.package("hello", "nixos-99.99")
  end

  test "reports a missing package" do
    assert {:error, %Lookup.Error{reason: :not_found, query: "missing"}} =
             Lookup.package("missing")
  end

  test "returns bounded package matches when the query is not exact", %{revision: revision} do
    for attribute <- ["hello", "hello-nix", "hello-wayland"] do
      package = Fixtures.package!(attribute)
      Fixtures.apply_package_revision!(revision, [{package, "1.0"}])
    end

    assert {:ok, %Lookup.Matches{kind: :package, query: "hell", items: items}} =
             Lookup.package("hell")

    assert Enum.map(items, & &1.name) == ["hello", "hello-nix", "hello-wayland"]
  end

  test "returns bounded option matches when the query is not exact", %{revision: revision} do
    for name <- ["services.nginx.enable", "services.nginx.package"] do
      option = Fixtures.option!(name)
      Fixtures.apply_option_revision!(revision, [{option, %{type: "boolean"}}])
    end

    assert {:ok, %Lookup.Matches{kind: :option, query: "nginx", items: items}} =
             Lookup.option("nginx")

    assert Enum.map(items, & &1.name) == ["services.nginx.enable", "services.nginx.package"]
  end
end
