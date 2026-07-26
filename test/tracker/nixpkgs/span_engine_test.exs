defmodule Tracker.Nixpkgs.SpanEngineTest do
  use Tracker.DataCase, async: true

  require Ash.Query

  alias Tracker.Nixpkgs.PackageSpan
  alias Tracker.Nixpkgs.SpanEngine
  alias Tracker.Nixpkgs.SpanEngine.Spec

  import Tracker.Fixtures, only: [channel!: 0, package!: 0]

  @t1 ~U[2020-01-01 00:00:00Z]
  @t2 ~U[2020-02-01 00:00:00Z]
  @t3 ~U[2020-03-01 00:00:00Z]

  defp spec do
    Spec.new(
      resource: PackageSpan,
      key_columns: [:package_id],
      payload_columns: [:version, :description]
    )
  end

  defp item(package, version, description \\ nil) do
    %{package_id: package.id, version: version, description: description}
  end

  describe "diff_and_apply/5 — open" do
    test "opens a span for a newly-seen key" do
      channel = channel!()
      pkg = package!()

      SpanEngine.diff_and_apply(spec(), channel.id, @t1, [item(pkg, "1.0", "a")])

      assert SpanEngine.reconstruct(spec(), channel.id, @t1) == %{
               [pkg.id] => %{version: "1.0", description: "a"}
             }
    end

    test "leaves an unchanged span in place (no reopen)" do
      channel = channel!()
      pkg = package!()

      SpanEngine.diff_and_apply(spec(), channel.id, @t1, [item(pkg, "1.0", "a")])
      SpanEngine.diff_and_apply(spec(), channel.id, @t2, [item(pkg, "1.0", "a")])

      # still a single span, opened at @t1
      assert [span] = all_spans(channel.id, pkg.id)
      assert bound?(span.valid.lower, @t1)
      assert span.valid.upper == :unbound
    end
  end

  describe "diff_and_apply/5 — change" do
    test "closes the old span at the boundary and opens a disjoint new one" do
      channel = channel!()
      pkg = package!()

      SpanEngine.diff_and_apply(spec(), channel.id, @t1, [item(pkg, "1.0", "a")])
      SpanEngine.diff_and_apply(spec(), channel.id, @t2, [item(pkg, "2.0", "a")])

      assert SpanEngine.reconstruct(spec(), channel.id, @t1) == %{
               [pkg.id] => %{version: "1.0", description: "a"}
             }

      assert SpanEngine.reconstruct(spec(), channel.id, @t2) == %{
               [pkg.id] => %{version: "2.0", description: "a"}
             }

      assert [closed, open] = all_spans(channel.id, pkg.id) |> Enum.sort_by(& &1.valid.lower)
      assert bound?(closed.valid.lower, @t1) and bound?(closed.valid.upper, @t2)
      assert bound?(open.valid.lower, @t2) and open.valid.upper == :unbound
    end
  end

  describe "diff_and_apply/5 — removal + completeness gating" do
    test "closes a span absent from a complete revision" do
      channel = channel!()
      keep = package!()
      drop = package!()

      SpanEngine.diff_and_apply(spec(), channel.id, @t1, [item(keep, "1.0"), item(drop, "1.0")])
      SpanEngine.diff_and_apply(spec(), channel.id, @t2, [item(keep, "1.0")], complete?: true)

      assert Map.keys(SpanEngine.reconstruct(spec(), channel.id, @t2)) == [[keep.id]]
      # both still existed at @t1
      assert SpanEngine.reconstruct(spec(), channel.id, @t1) |> map_size() == 2
    end

    test "does NOT close absent keys for an incomplete revision" do
      channel = channel!()
      keep = package!()
      drop = package!()

      SpanEngine.diff_and_apply(spec(), channel.id, @t1, [item(keep, "1.0"), item(drop, "1.0")])
      SpanEngine.diff_and_apply(spec(), channel.id, @t2, [item(keep, "1.0")], complete?: false)

      # drop's span stays open, so it's still present at @t2
      assert SpanEngine.reconstruct(spec(), channel.id, @t2) |> map_size() == 2
    end
  end

  describe "diff_and_apply/5 — re-addition" do
    test "a removed-then-readded key gets a second disjoint span" do
      channel = channel!()
      pkg = package!()

      SpanEngine.diff_and_apply(spec(), channel.id, @t1, [item(pkg, "1.0")])
      SpanEngine.diff_and_apply(spec(), channel.id, @t2, [], complete?: true)
      SpanEngine.diff_and_apply(spec(), channel.id, @t3, [item(pkg, "1.0")])

      assert [first, second] = all_spans(channel.id, pkg.id) |> Enum.sort_by(& &1.valid.lower)
      assert bound?(first.valid.lower, @t1) and bound?(first.valid.upper, @t2)
      assert bound?(second.valid.lower, @t3) and second.valid.upper == :unbound

      # gap: absent at @t2 (half-open close), present at @t1 and @t3
      assert SpanEngine.reconstruct(spec(), channel.id, @t2) == %{}
      assert SpanEngine.reconstruct(spec(), channel.id, @t1) |> map_size() == 1
      assert SpanEngine.reconstruct(spec(), channel.id, @t3) |> map_size() == 1
    end
  end

  describe "per-channel isolation" do
    test "spans in one channel do not affect another" do
      c1 = channel!()
      c2 = channel!()
      pkg = package!()

      SpanEngine.diff_and_apply(spec(), c1.id, @t1, [item(pkg, "1.0")])

      assert SpanEngine.reconstruct(spec(), c1.id, @t1) |> map_size() == 1
      assert SpanEngine.reconstruct(spec(), c2.id, @t1) == %{}
    end
  end

  describe "payload fingerprint" do
    test "stores the incoming item's fingerprint on every opened span" do
      channel = channel!()
      pkg = package!()
      item = item(pkg, "1.0", "a")

      SpanEngine.diff_and_apply(spec(), channel.id, @t1, [item])

      assert [span] = all_spans(channel.id, pkg.id)
      assert span.fingerprint == spec().fingerprint_fn.(item)
    end

    test "a span with no stored fingerprint is treated as changed" do
      channel = channel!()
      pkg = package!()
      item = item(pkg, "1.0", "a")

      SpanEngine.diff_and_apply(spec(), channel.id, @t1, [item])
      clear_fingerprints!(channel.id)

      # Same payload, so without a fingerprint to compare this must fail safe by
      # reopening rather than silently treating it as unchanged.
      SpanEngine.diff_and_apply(spec(), channel.id, @t2, [item])

      assert [closed, open] = all_spans(channel.id, pkg.id) |> Enum.sort_by(& &1.valid.lower)
      assert bound?(closed.valid.upper, @t2)
      assert open.valid.upper == :unbound
      assert open.fingerprint == spec().fingerprint_fn.(item)
    end

    test "backfill_fingerprints/2 populates open spans and leaves closed ones alone" do
      channel = channel!()
      changed = package!()
      still_open = package!()

      SpanEngine.diff_and_apply(spec(), channel.id, @t1, [
        item(changed, "1.0", "a"),
        item(still_open, "1.0", "a")
      ])

      # Close one span by changing its payload, then wipe every fingerprint to
      # simulate rows written before the column existed.
      SpanEngine.diff_and_apply(spec(), channel.id, @t2, [
        item(changed, "2.0", "a"),
        item(still_open, "1.0", "a")
      ])

      clear_fingerprints!(channel.id)

      assert {:ok, 2} = SpanEngine.backfill_fingerprints(spec(), channel.id, max_concurrency: 1)

      [closed] =
        all_spans(channel.id, changed.id)
        |> Enum.filter(&match?(%Postgrex.Range{upper: %DateTime{}}, &1.valid))

      assert is_nil(closed.fingerprint)

      for {pkg, version} <- [{changed, "2.0"}, {still_open, "1.0"}] do
        [open] =
          all_spans(channel.id, pkg.id)
          |> Enum.filter(&(&1.valid.upper == :unbound))

        assert open.fingerprint == spec().fingerprint_fn.(item(pkg, version, "a"))
      end
    end

    test "a backfilled fingerprint leaves an unchanged span in place" do
      channel = channel!()
      pkg = package!()
      item = item(pkg, "1.0", "a")

      SpanEngine.diff_and_apply(spec(), channel.id, @t1, [item])
      clear_fingerprints!(channel.id)
      assert {:ok, 1} = SpanEngine.backfill_fingerprints(spec(), channel.id, max_concurrency: 1)

      SpanEngine.diff_and_apply(spec(), channel.id, @t2, [item])

      assert [span] = all_spans(channel.id, pkg.id)
      assert span.valid.upper == :unbound
      assert bound?(span.valid.lower, @t1)
    end
  end

  describe "diff_and_apply/5 — batched writes" do
    test "opens every span when the open set spans multiple batches" do
      channel = channel!()
      pkgs = for _ <- 1..5, do: package!()
      items = Enum.map(pkgs, &item(&1, "1.0", "a"))

      SpanEngine.diff_and_apply(spec(), channel.id, @t1, items, batch_size: 2)

      assert SpanEngine.reconstruct(spec(), channel.id, @t1) |> map_size() == 5
    end

    test "closes every changed span when the close set spans multiple batches" do
      channel = channel!()
      pkgs = for _ <- 1..5, do: package!()
      SpanEngine.diff_and_apply(spec(), channel.id, @t1, Enum.map(pkgs, &item(&1, "1.0")))

      SpanEngine.diff_and_apply(spec(), channel.id, @t2, Enum.map(pkgs, &item(&1, "2.0")),
        batch_size: 2
      )

      recon = SpanEngine.reconstruct(spec(), channel.id, @t2)
      assert map_size(recon) == 5
      assert Enum.all?(recon, fn {_k, v} -> v.version == "2.0" end)
    end

    test "keeps a wide payload under the bind-parameter limit at the default batch size" do
      # Postgres caps a statement at 65_535 bind parameters. PackageSpan's full
      # payload is 27 columns per row, so a fixed 5_000-row batch overflows it.
      channel = channel!()

      wide_spec =
        Spec.new(
          resource: PackageSpan,
          key_columns: [:package_id],
          payload_columns: PackageSpan.payload_columns()
        )

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      count = 2_500

      {_, packages} =
        Tracker.Repo.insert_all(
          "packages",
          Enum.map(1..count, fn i ->
            %{
              attribute: "wide-pkg-#{System.unique_integer([:positive])}-#{i}",
              inserted_at: now,
              updated_at: now
            }
          end),
          returning: [:id]
        )

      items =
        Enum.map(packages, fn %{id: id} ->
          wide_spec.payload_columns
          |> Map.new(&{&1, nil})
          |> Map.merge(%{package_id: id, version: "1.0"})
        end)

      SpanEngine.diff_and_apply(wide_spec, channel.id, @t1, items)

      assert SpanEngine.reconstruct(wide_spec, channel.id, @t1) |> map_size() == count
    end

    test "raises (no silent success) when a span write fails" do
      pkg = package!()

      assert_raise Postgrex.Error, fn ->
        SpanEngine.diff_and_apply(spec(), 999_999, @t1, [item(pkg, "1.0", "a")])
      end
    end
  end

  describe "replay/3" do
    test "folds revisions in chronological order, gating on completeness" do
      channel = channel!()
      a = package!()
      b = package!()

      revisions = [
        %{released_at: @t1, complete?: true, incoming: [item(a, "1.0"), item(b, "1.0")]},
        %{released_at: @t2, complete?: true, incoming: [item(a, "2.0")]},
        %{released_at: @t3, complete?: true, incoming: [item(a, "2.0"), item(b, "3.0")]}
      ]

      SpanEngine.replay(spec(), channel.id, revisions)

      assert SpanEngine.reconstruct(spec(), channel.id, @t1) == %{
               [a.id] => %{version: "1.0", description: nil},
               [b.id] => %{version: "1.0", description: nil}
             }

      # b removed at @t2, a bumped
      assert Map.keys(SpanEngine.reconstruct(spec(), channel.id, @t2)) == [[a.id]]

      # b re-added at @t3
      assert SpanEngine.reconstruct(spec(), channel.id, @t3) == %{
               [a.id] => %{version: "2.0", description: nil},
               [b.id] => %{version: "3.0", description: nil}
             }
    end
  end

  describe "verify/4" do
    test ":ok when reconstruction matches the expected source set" do
      channel = channel!()
      pkg = package!()
      SpanEngine.diff_and_apply(spec(), channel.id, @t1, [item(pkg, "1.0", "a")])

      expected = %{[pkg.id] => %{version: "1.0", description: "a"}}
      assert SpanEngine.verify(spec(), channel.id, @t1, expected) == :ok
    end

    test "reports the difference on mismatch" do
      channel = channel!()
      pkg = package!()
      SpanEngine.diff_and_apply(spec(), channel.id, @t1, [item(pkg, "1.0", "a")])

      expected = %{[pkg.id] => %{version: "9.9", description: "a"}}

      assert {:error, %{payload_mismatch: [_ | _]}} =
               SpanEngine.verify(spec(), channel.id, @t1, expected)
    end
  end

  describe "fingerprint stability" do
    test "a payload with trailing whitespace does not churn across revisions" do
      channel = channel!()
      pkg = package!()

      SpanEngine.diff_and_apply(spec(), channel.id, @t1, [item(pkg, "1.0", "a desc\n")])

      SpanEngine.diff_and_apply(spec(), channel.id, @t2, [item(pkg, "1.0", "a desc\n")],
        complete?: true
      )

      assert all_spans(channel.id, pkg.id) |> length() == 1
      assert SpanEngine.reconstruct(spec(), channel.id, @t1)[[pkg.id]].description == "a desc\n"
    end
  end

  defp bound?(actual, expected), do: DateTime.compare(actual, expected) == :eq

  defp all_spans(channel_id, package_id) do
    PackageSpan
    |> Ash.Query.filter(channel_id == ^channel_id and package_id == ^package_id)
    |> Ash.read!()
  end

  # Simulates spans written before the fingerprint column existed.
  defp clear_fingerprints!(channel_id) do
    Tracker.Repo.update_all(
      from(s in "package_spans", where: s.channel_id == ^channel_id),
      set: [fingerprint: nil]
    )
  end
end
