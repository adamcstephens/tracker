defmodule Tracker.Discord.ConsumerTest do
  use ExUnit.Case, async: true

  alias Tracker.Discord.Consumer

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
end
