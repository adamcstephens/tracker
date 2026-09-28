defmodule Tracker.Nixpkgs.UpdateLogPageTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{Package, UpdateLogPage}

  test "matches exact and terminal suffix variants without changing source URLs" do
    pages = [
      {"curl", "https://example.test/curl/"},
      {"curlFull", "https://example.test/curlFull/"},
      {"curlMinimal", "https://example.test/curlMinimal/"},
      {"ffmpeg_4-full", "https://example.test/ffmpeg_4-full/"},
      {"ffmpeg_8", "https://example.test/ffmpeg_8/"}
    ]

    for {attribute, url} <- pages, do: UpdateLogPage.upsert!(attribute, url)

    assert Enum.map(Package.log_pages!("curl"), &{&1.attribute, &1.url}) ==
             Enum.take(pages, 3)

    assert Enum.map(Package.log_pages!("curlFull"), & &1.attribute) ==
             ["curlFull", "curl", "curlMinimal"]

    assert Enum.map(Package.log_pages!("ffmpeg_4-minimal"), & &1.attribute) == ["ffmpeg_4-full"]
    assert Enum.map(Package.log_pages!("ffmpeg_8"), & &1.attribute) == ["ffmpeg_8"]
  end

  test "recognized sets compose with suffixes but unknown namespaces remain isolated" do
    for attribute <- [
          "beam26Packages.elixir",
          "beamMinimal28Packages.elixirFull",
          "fooPackages.example",
          "barPackages.example",
          "example",
          "python313Packages.numpy",
          "rubyPackages_3_4.numpy"
        ] do
      UpdateLogPage.upsert!(attribute, "https://example.test/#{attribute}/")
    end

    assert Enum.map(Package.log_pages!("beam28Packages.elixirMinimal"), & &1.attribute) ==
             ["beam26Packages.elixir", "beamMinimal28Packages.elixirFull"]

    assert Enum.map(Package.log_pages!("fooPackages.example"), & &1.attribute) ==
             ["fooPackages.example"]

    assert Package.log_pages!("bazPackages.example") == []
    assert Package.log_pages!("example") |> Enum.map(& &1.attribute) == ["example"]

    assert Enum.map(Package.log_pages!("python314Packages.numpy"), & &1.attribute) ==
             ["python313Packages.numpy"]

    assert Package.log_pages!("rubyPackages_3_4.numpy") |> Enum.map(& &1.attribute) ==
             ["rubyPackages_3_4.numpy"]
  end

  test "nonterminal and unapproved suffixes do not match" do
    UpdateLogPage.upsert!("curlWithGnuTls", "https://example.test/curlWithGnuTls/")
    UpdateLogPage.upsert!("curl-full-extra", "https://example.test/curl-full-extra/")
    UpdateLogPage.upsert!("curlfull", "https://example.test/curlfull/")

    assert Package.log_pages!("curl") == []
    assert Package.log_pages!("curl-headless") == []
  end
end
