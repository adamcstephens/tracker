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

    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        conn.method == "PUT" ->
          Plug.Conn.send_resp(conn, 200, "")

        String.ends_with?(conn.request_path, "packages.json.br") ->
          Plug.Conn.send_resp(conn, 200, Tracker.PackageStreamFixtures.small_packages_br())

        true ->
          Plug.Conn.send_resp(conn, 404, "not found")
      end
    end)

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

    channel_revision =
      Ash.create!(Tracker.Nixpkgs.ChannelRevision, %{
        channel_id: channel.id,
        revision: "abc123def4567890",
        released_at: ~U[2026-07-01 10:00:00Z]
      })

    :ok =
      LoadPackages.run(%StepContext{
        pipeline: %Tracker.Ingestion.Pipeline{base_url: @base_url, channel_id: channel.id},
        channel_revision: channel_revision
      })

    channel
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
