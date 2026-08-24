defmodule Tracker.Discord.ConsumerTest do
  use Tracker.DataCase, async: true

  alias Tracker.Discord.Consumer
  alias Tracker.Fixtures

  test "registers the package and NixOS lookup commands" do
    assert [package, nixos] = Consumer.commands()

    assert package.name == "package"
    assert package.description == "Look up a package in Tracker"

    assert Enum.map(package.options, &Map.take(&1, [:name, :type, :required])) == [
             %{name: "search_term", type: 3, required: true},
             %{name: "channel", type: 3, required: false}
           ]

    assert nixos.name == "nixos"
    assert nixos.description == "Look up a NixOS option in Tracker"

    assert Enum.map(nixos.options, &Map.take(&1, [:name, :type, :required])) == [
             %{name: "search_term", type: 3, required: true},
             %{name: "channel", type: 3, required: false}
           ]
  end

  test "renders a package at the default channel revision" do
    {revision, package} = package_at_default_channel("hello")

    Fixtures.apply_package_revision!(revision, [
      {package, %{version: "2.12.1", description: "A familiar greeting.", broken: true}}
    ])

    assert %{type: 4, data: %{flags: 64, embeds: [embed]}} =
             Consumer.response_for("package", "hello", nil)

    assert embed.title == "hello"
    assert Enum.any?(embed.fields, &match?(%{name: "Version", value: "2.12.1"}, &1))
    assert Enum.any?(embed.fields, &match?(%{name: "Availability", value: "broken"}, &1))
    assert %{name: "Tracker", value: tracker_link("/packages/hello", revision)} in embed.fields
  end

  test "renders an option at the default channel revision" do
    {revision, _package} = package_at_default_channel("unused")
    option = Fixtures.option!("services.nginx.enable")

    Fixtures.apply_option_revision!(revision, [
      {option, %{type: "boolean", description: "Enable nginx.", read_only: true}}
    ])

    assert %{type: 4, data: %{flags: 64, embeds: [embed]}} =
             Consumer.response_for("nixos", "services.nginx.enable", nil)

    assert embed.title == "services.nginx.enable"
    assert Enum.any?(embed.fields, &match?(%{name: "Read-only", value: "Yes"}, &1))
  end

  test "renders bounded private matches for non-exact queries" do
    {revision, _package} = package_at_default_channel("hello")

    for attribute <- ["hello-nix"] do
      package = Fixtures.package!(attribute)
      Fixtures.apply_package_revision!(revision, [{package, "1.0"}])
    end

    assert %{type: 4, data: %{flags: 64, content: content}} =
             Consumer.response_for("package", "hell", nil)

    assert content =~ "Several package results"
    assert content =~ "hello-nix"
  end

  test "renders missing and unavailable results privately" do
    {revision, _package} = package_at_default_channel("unused")

    assert %{data: %{flags: 64, content: "No result found for `missing`."}} =
             Consumer.response_for("package", "missing", nil)

    assert %{data: %{flags: 64, content: "Unknown channel `nixos-99.99`."}} =
             Consumer.response_for("package", "hello", "nixos-99.99")

    assert revision.revision == "abc123456789"
  end

  defp package_at_default_channel(attribute) do
    channel = Fixtures.channel!("nixos-unstable")

    revision =
      Fixtures.channel_revision!(channel, %{
        revision: "abc123456789",
        released_at: ~U[2026-08-23 12:00:00Z]
      })

    {revision, Fixtures.package!(attribute)}
  end

  defp tracker_link(path, revision) do
    "[Open in Tracker](#{TrackerWeb.Endpoint.url()}#{path}?channel=nixos-unstable&rev=#{revision.revision})"
  end
end
