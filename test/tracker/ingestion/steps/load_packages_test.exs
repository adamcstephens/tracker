defmodule Tracker.Ingestion.Steps.LoadPackagesTest do
  use Tracker.DataCase, async: false

  alias Tracker.Ingestion.StepContext
  alias Tracker.Ingestion.Steps.LoadPackages
  alias Tracker.Nixpkgs.{Channel, PackageSpan, S3Cache}
  alias Tracker.Nixpkgs.{Maintainer, Package, PackageMaintainer, PackageTeam, Team, TeamMember}

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

  test "problem-only changes preserve history, clear problems, and leave version history unchanged" do
    problem = %{
      "kind" => "future-kind",
      "message" => "  Exact upstream text\n",
      "urls" => ["https://example.test/advisory"]
    }

    Tracker.PackageStreamFixtures.json()
    |> put_in(["packages", "hello", "meta", "problems"], %{"zeta" => problem})
    |> stub_fixture()

    channel = run_step!("nixos-24.11")
    original = open_span!(channel, "hello")
    assert [stored] = Map.fetch!(original, :problems)
    assert stored.__struct__ == Tracker.Nixpkgs.Problem

    assert {stored.id, stored.kind, stored.message, stored.urls} ==
             {"zeta", problem["kind"], problem["message"], problem["urls"]}

    changed_problem = %{problem | "message" => "Changed text"}

    Tracker.PackageStreamFixtures.json()
    |> put_in(["packages", "hello", "meta", "problems"], %{"zeta" => changed_problem})
    |> stub_fixture()

    run_revision!(channel, "problem-changed", ~U[2026-07-02 10:00:00Z])
    changed = open_span!(channel, "hello")
    assert changed.id != original.id
    assert [%{message: "Changed text"}] = changed.problems
    assert changed.version == original.version

    stub_fixture(Tracker.PackageStreamFixtures.json())
    run_revision!(channel, "problem-cleared", ~U[2026-07-03 10:00:00Z])
    cleared = open_span!(channel, "hello")
    assert cleared.problems == []
    assert cleared.id != changed.id

    package_id = original.package_id
    history = Tracker.Nixpkgs.PackageHistory
    pinned = history.metadata_at(channel.id, ~U[2026-07-01 10:00:00Z], [package_id])
    assert pinned[package_id].problems == [stored]
    assert history.current_metadata(channel.id, [package_id])[package_id].problems == []

    assert {[%{version: "2.12.1"}], 1} =
             history.version_changes_by_package(package_id, channel_id: channel.id)

    spans =
      PackageSpan.by_package!(package_id, channel.id) |> Enum.sort_by(& &1.valid.lower, DateTime)

    assert [first, second, third] = spans
    assert first.valid.upper == second.valid.lower
    assert second.valid.upper == third.valid.lower
  end

  test "problem key order causes no churn and problems stay scoped to attribute and channel" do
    package = Tracker.PackageStreamFixtures.json()["packages"]["hello"]

    first_meta =
      ~s({"problems":{"z":{"kind":"new","message":"Z"},"a":{"kind":"known","message":"A"}}})

    second_meta =
      ~s({"problems":{"a":{"message":"A","kind":"known"},"z":{"message":"Z","kind":"new"}}})

    body = fn meta ->
      package_json = package |> Map.delete("meta") |> Jason.encode!()
      with_meta = String.trim_trailing(package_json, "}") <> ~s(,"meta":#{meta}})

      ExBrotli.compress!(
        ~s({"version":2,"packages":{"hello":#{with_meta},"alias":#{Jason.encode!(package)}}})
      )
    end

    stub_packages_body(body.(first_meta))
    channel = run_step!("nixos-24.11")
    original = open_span!(channel, "hello")
    assert Enum.map(Map.fetch!(original, :problems), &{&1.id, &1.urls}) == [{"a", []}, {"z", []}]
    assert open_span!(channel, "alias").problems == []

    stub_packages_body(body.(second_meta))
    run_revision!(channel, "reordered", ~U[2026-07-02 10:00:00Z])
    assert open_span!(channel, "hello").id == original.id

    stub_fixture(%{"version" => 2, "packages" => %{"hello" => package}})
    other_channel = run_step!("nixos-unstable")
    assert open_span!(other_channel, "hello").problems == []
    assert open_span!(channel, "hello").problems == original.problems
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

  test "reconciles all metadata relations without rewriting retained rows" do
    channel = run_step!(Tracker.Ingestion.StepGraph.metadata_channel())
    package = Package.get_by_attribute!("with_maintainers")
    retained = relation_rows()
    team = Team.get_by_short_name!("nixos-team")

    fixture = Tracker.PackageStreamFixtures.json()
    entry = fixture["packages"]["with_maintainers"]
    changed = put_in(fixture, ["packages", "another"], entry)
    stub_fixture(changed)
    run_revision!(channel, "second", ~U[2026-07-02 10:00:00Z])

    for {resource, rows} <- retained do
      assert Enum.all?(rows, &(&1 in resource.read!(query: [sort: :id])))
    end

    assert Team.get_by_short_name!("nixos-team") == team

    changed = put_in(changed, ["packages", "with_maintainers", "meta"], %{})
    stub_fixture(changed)
    run_revision!(channel, "third", ~U[2026-07-03 10:00:00Z])
    assert Package.get_by_attribute!(package.attribute, load: [:maintainers]).maintainers == []
    assert Package.get_by_attribute!(package.attribute, load: [:teams]).teams == []
    assert Team.get_by_short_name!("nixos-team").id == team.id
    assert length(TeamMember.read!()) == 1
    assert length(PackageMaintainer.read!()) == 1
    assert length(PackageTeam.read!()) == 1

    unchanged = relation_rows()
    run_revision!(channel, "third", ~U[2026-07-03 10:00:00Z])
    assert relation_rows() == unchanged

    stub_fixture(put_in(changed, ["packages"], %{}))
    run_revision!(channel, "empty", ~U[2026-07-04 10:00:00Z])
    assert relation_rows() == [{PackageMaintainer, []}, {TeamMember, []}, {PackageTeam, []}]
    assert Team.read!() == []
    assert Maintainer.get_by_github!("alice").id
    assert Maintainer.get_by_github!("bob").id
    assert Package.get_by_attribute!(package.attribute).id == package.id
  end

  test "updates teams in place and clears removed members and optional metadata" do
    channel = run_step!(Tracker.Ingestion.StepGraph.metadata_channel())
    team = Team.get_by_short_name!("nixos-team")
    [join] = PackageTeam.read!()

    Tracker.PackageStreamFixtures.json()
    |> put_in(["packages", "with_maintainers", "meta", "teams"], [
      %{"shortName" => "NIXOS-TEAM", "members" => []}
    ])
    |> stub_fixture()

    run_revision!(channel, "second", ~U[2026-07-02 10:00:00Z])
    updated = Team.get_by_short_name!("nixos-team")
    assert updated.id == team.id
    assert updated.scope == nil
    assert updated.github == nil
    assert updated.github_id == nil
    assert TeamMember.read!() == []
    assert PackageTeam.read!() == [join]
    assert Maintainer.get_by_github!("bob").id
  end

  test "a failed parse leaves committed metadata unchanged" do
    channel = run_step!(Tracker.Ingestion.StepGraph.metadata_channel())
    before = {relation_rows(), Team.read!(), Maintainer.read!(), Channel.by_id!(channel.id)}
    stub_packages_body(ExBrotli.compress!("{"))

    assert_raise RuntimeError, ~r/PackageStream/, fn ->
      run_revision!(channel, "bad", ~U[2026-07-02 10:00:00Z])
    end

    assert {relation_rows(), Team.read!(), Maintainer.read!(), Channel.by_id!(channel.id)} ==
             before
  end

  defp stub_fixture(fixture) do
    fixture |> Jason.encode!() |> ExBrotli.compress!() |> stub_packages_body()
  end

  defp relation_rows do
    for resource <- [PackageMaintainer, TeamMember, PackageTeam] do
      {resource, resource.read!(query: [sort: :id])}
    end
  end
end
