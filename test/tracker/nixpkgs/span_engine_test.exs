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

  defp bound?(actual, expected), do: DateTime.compare(actual, expected) == :eq

  defp all_spans(channel_id, package_id) do
    PackageSpan
    |> Ash.Query.filter(channel_id == ^channel_id and package_id == ^package_id)
    |> Ash.read!()
  end
end
