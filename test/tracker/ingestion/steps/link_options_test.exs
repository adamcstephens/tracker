defmodule Tracker.Ingestion.Steps.LinkOptionsTest do
  use Tracker.DataCase, async: false

  alias Tracker.Fixtures
  alias Tracker.Ingestion.StepContext
  alias Tracker.Ingestion.Steps.LinkOptions
  alias Tracker.Nixpkgs.{ChannelRevision, OptionPackageSpan}

  @base_url "http://upstream.test/release"
  @option "services.victorialogs.package"

  setup do
    Application.put_env(:tracker, :s3_cache, %{
      bucket: "test-bucket",
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      endpoint: "http://localhost:4444",
      region: "garage",
      plug: {Req.Test, __MODULE__}
    })

    on_exit(fn -> Application.delete_env(:tracker, :s3_cache) end)

    channel = Fixtures.channel!()

    %{
      channel: channel,
      logs: Fixtures.package!("victorialogs"),
      metrics: Fixtures.package!("victoriametrics")
    }
  end

  defp stub_options(options_map) do
    body = options_map |> :json.encode() |> to_string() |> ExBrotli.compress!()

    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        conn.method == "PUT" ->
          Plug.Conn.send_resp(conn, 200, "")

        String.ends_with?(conn.request_path, "options.json.br") ->
          Plug.Conn.send_resp(conn, 200, body)

        true ->
          Plug.Conn.send_resp(conn, 404, "not found")
      end
    end)
  end

  defp run_revision!(channel, revision, released_at, options_map) do
    Fixtures.option!(@option)
    stub_options(options_map)

    channel_revision =
      ChannelRevision.create!(%{
        channel_id: channel.id,
        revision: revision,
        released_at: released_at
      })

    :ok =
      LinkOptions.run(%StepContext{
        pipeline: %Tracker.Ingestion.Pipeline{base_url: @base_url, channel_id: channel.id},
        channel_revision: channel_revision
      })

    channel_revision
  end

  defp entry(attribute) do
    %{@option => %{"type" => "package", "default" => "pkgs.#{attribute}"}}
  end

  defp option_id do
    Tracker.Nixpkgs.Option.id_map!() |> Enum.find(&(&1.name == @option)) |> Map.fetch!(:id)
  end

  defp linked_attributes(channel_revision) do
    channel_revision.channel_id
    |> OptionPackageSpan.packages_for_options_at!(channel_revision.released_at, [option_id()])
    |> Enum.map(& &1.package.attribute)
  end

  test "opens a link span for each extracted option↔package pair", %{channel: channel} do
    cr = run_revision!(channel, "linkopt1", ~U[2026-04-01 10:00:00Z], entry("victoriametrics"))

    assert linked_attributes(cr) == ["victoriametrics"]
  end

  test "closes a link the revision no longer declares", %{channel: channel} do
    cr1 = run_revision!(channel, "linkopt1", ~U[2026-04-01 10:00:00Z], entry("victoriametrics"))
    cr2 = run_revision!(channel, "linkopt2", ~U[2026-04-02 10:00:00Z], entry("victorialogs"))

    assert linked_attributes(cr1) == ["victoriametrics"]
    assert linked_attributes(cr2) == ["victorialogs"]
  end
end
