defmodule Tracker.Ingestion.Steps.LoadPackagesTest do
  use Tracker.DataCase, async: false

  alias Tracker.Ingestion.StepContext
  alias Tracker.Ingestion.Steps.LoadPackages
  alias Tracker.Nixpkgs.{Channel, PackageSpan, S3Cache}

  @base_url "http://upstream.test/release"

  setup do
    config = %S3Cache.Config{
      bucket: "test-bucket",
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      endpoint: "http://localhost:4444",
      region: "garage",
      plug: {Req.Test, __MODULE__}
    }

    Application.put_env(:tracker, :s3_cache, Map.from_struct(config))
    on_exit(fn -> Application.delete_env(:tracker, :s3_cache) end)

    stub_packages_body(Tracker.PackageStreamFixtures.small_packages_br())

    :ok
  end

  defp run_step!(channel_name) do
    channel =
      Channel.create!(%{
        name: channel_name,
        display_name: channel_name,
        status: :active,
        is_stable: false
      })

    run_revision!(channel, "abc123def4567890", ~U[2026-07-01 10:00:00Z])

    channel
  end

  defp run_revision!(channel, revision, released_at) do
    channel_revision =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel.id,
        revision: revision,
        released_at: released_at
      })

    :ok =
      LoadPackages.run(%StepContext{
        pipeline: %Tracker.Ingestion.Pipeline{base_url: @base_url, channel_id: channel.id},
        channel_revision: channel_revision
      })

    channel_revision
  end

  defp stub_packages_body(body) do
    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        conn.method == "PUT" ->
          Plug.Conn.send_resp(conn, 200, "")

        String.ends_with?(conn.request_path, "packages.json.br") ->
          Plug.Conn.send_resp(conn, 200, body)

        true ->
          Plug.Conn.send_resp(conn, 404, "not found")
      end
    end)
  end

  defp open_span!(channel, attribute) do
    package = Tracker.Nixpkgs.Package.get_by_attribute!(attribute)

    [span] =
      PackageSpan.current_for_packages!(channel.id, [package.id])

    span
  end

  test "stores metadata on spans for a non-metadata channel" do
    channel = run_step!("nixos-24.11")

    span = open_span!(channel, "hello")

    assert span.version == "2.12.1"
    assert span.description == "A program that produces a familiar, friendly greeting"
    assert span.homepage == ["https://www.gnu.org/software/hello/"]
    assert span.position == "pkgs/by-name/he/hello/package.nix"
    assert span.licenses == ["GPL-3.0-or-later"]
  end

  test "stores extended metadata on spans" do
    channel = run_step!("nixos-24.11")

    span = open_span!(channel, "hello")

    assert span.pname == "hello"
    assert span.outputs == ["man", "out"]
    assert span.default_output == "out"
    assert span.long_description == "GNU Hello prints a greeting.\nIt is also a demo."
    assert span.main_program == "hello"
    assert span.broken == false
    assert span.unfree == false
    assert is_nil(span.insecure)
    assert is_nil(span.unsupported)
    assert span.changelog == ["https://www.gnu.org/software/hello/NEWS"]
    assert span.download_page == "https://ftp.gnu.org/gnu/hello/"
    assert span.source_provenance == ["fromSource"]
    assert span.platforms == ["x86_64-linux", "aarch64-darwin"]
    assert is_nil(span.bad_platforms)
    assert is_nil(span.known_vulnerabilities)
  end

  test "stores normalized platform patterns and availability flags" do
    channel = run_step!("nixos-24.11")

    span = open_span!(channel, "platform_patterns")

    assert span.insecure == true
    assert span.unsupported == true
    assert span.known_vulnerabilities == ["CVE-2024-0001: buffer overflow"]
    assert span.platforms == ["x86_64-linux", "mips64n32", "x86-linux"]
    assert span.bad_platforms == ["darwin"]
    assert is_nil(span.outputs)
  end

  test "a changed payload field closes and reopens the span" do
    channel = run_step!("nixos-24.11")

    changed =
      Tracker.PackageStreamFixtures.json()
      |> put_in(["packages", "hello", "meta", "mainProgram"], "hello-renamed")
      |> Jason.encode!()
      |> ExBrotli.compress!()

    stub_packages_body(changed)
    run_revision!(channel, "def456abc7890123", ~U[2026-07-02 10:00:00Z])

    package = Tracker.Nixpkgs.Package.get_by_attribute!("hello")
    spans = PackageSpan.by_package!(package.id, channel.id)

    assert [closed] =
             Enum.filter(spans, &match?(%Postgrex.Range{upper: %DateTime{}}, &1.valid))

    assert closed.main_program == "hello"
    assert DateTime.compare(closed.valid.upper, ~U[2026-07-02 10:00:00Z]) == :eq

    assert [open] =
             Enum.filter(
               spans,
               &match?(%Postgrex.Range{upper: upper} when upper in [nil, :unbound], &1.valid)
             )

    assert open.main_program == "hello-renamed"
  end

  test "logs unknown platform patterns from the stream meta in one warning" do
    stub_packages_body(Tracker.PackageStreamFixtures.unknown_platform_br())

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        run_step!("nixos-24.11")
      end)

    assert length(String.split(log, "[warning]")) == 2
    assert log =~ "2 unknown platform patterns"
    assert log =~ "frobnitz"
    assert log =~ "quux"
  end

  test "does not load maintainers or teams for a non-metadata channel" do
    run_step!("nixos-24.11")

    assert Tracker.Nixpkgs.Maintainer.id_map!() == []
    assert Tracker.Nixpkgs.Team.id_map!() == []
  end

  test "loads maintainers and teams for the metadata channel" do
    channel = run_step!(Tracker.Ingestion.StepGraph.metadata_channel())

    span = open_span!(channel, "hello")
    assert span.description == "A program that produces a familiar, friendly greeting"

    maintainers = Tracker.Nixpkgs.Maintainer.id_map!()
    assert Enum.any?(maintainers, &(&1.github_id == 12345))

    teams = Tracker.Nixpkgs.Team.id_map!()
    assert Enum.any?(teams, &(to_string(&1.short_name) == "nixos-team"))
  end
end
