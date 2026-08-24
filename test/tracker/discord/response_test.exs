defmodule Tracker.Discord.ResponseTest do
  use ExUnit.Case, async: true

  alias Tracker.Discord.{Lookup, Response}

  test "renders private package results with escaped, shortened text" do
    result = %Lookup.Package{
      attribute: "hello",
      version: "2.12.1",
      description: String.duplicate("<greeting> ", 300),
      broken: true,
      unfree: false,
      insecure: false,
      unsupported: false,
      maintainers: ["alice"],
      teams: ["nixpkgs"],
      channel: "nixos-unstable",
      revision: "abc123456789",
      url: "https://tracker.example/packages/hello"
    }

    assert %{type: 4, data: %{flags: 64, embeds: [embed]}} = Response.render({:ok, result})
    assert embed.title == "hello"
    assert embed.description =~ "&lt;greeting&gt;"
    assert String.length(embed.description) <= 1_024

    assert %{name: "Tracker", value: "[Open in Tracker](https://tracker.example/packages/hello)"} in embed.fields
  end

  test "renders missing results privately" do
    error = %Lookup.Error{reason: :not_found, query: "missing", channel: nil}

    assert %{type: 4, data: %{flags: 64, content: "No result found for `missing`."}} =
             Response.render({:error, error})
  end
end
