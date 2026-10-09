defmodule Tracker.Nixpkgs.RevisionComparisonTest do
  use Tracker.DataCase, async: true

  alias Tracker.Fixtures
  alias Tracker.Nixpkgs.RevisionComparison
  alias Tracker.Nixpkgs.RevisionComparison.{Counts, OptionRow, PackageRow, Page}

  defp revisions do
    channel = Fixtures.channel!()

    revisions =
      Enum.map(
        [~U[2026-04-01 10:00:00Z], ~U[2026-04-08 10:00:00Z], ~U[2026-04-15 10:00:00Z]],
        fn at ->
          Fixtures.channel_revision!(channel, %{released_at: at})
        end
      )

    List.to_tuple(revisions)
  end

  test "first revisions have no comparison rather than treating everything as added" do
    {_from, _mid, to} = revisions()
    package = Fixtures.package!()
    option = Fixtures.option!()
    Fixtures.apply_package_revision!(to, [{package, "1"}])
    Fixtures.apply_option_revision!(to, [{option, %{type: "bool"}}])

    assert RevisionComparison.packages(nil, to) == %Page{}
    assert RevisionComparison.options(nil, to) == %Page{}
  end

  test "package comparisons net intermediate versions, removals, reappearances and transient additions" do
    {from, mid, to} = revisions()
    changed = Fixtures.package!("net.changed")
    reverted = Fixtures.package!("net.reverted")
    reappeared = Fixtures.package!("net.reappeared")
    removed = Fixtures.package!("net.removed")
    added = Fixtures.package!("net.added")
    transient = Fixtures.package!("net.transient")
    metadata_only = Fixtures.package!("net.metadata")

    Fixtures.apply_package_revision!(from, [
      {changed, "1"},
      {reverted, "1"},
      {reappeared, "1"},
      {removed, "1"},
      {metadata_only, %{version: "1", description: "old"}}
    ])

    Fixtures.apply_package_revision!(mid, [
      {changed, "2"},
      {reverted, "2"},
      {removed, "2"},
      {added, "1"},
      {transient, "1"}
    ])

    Fixtures.remove_package!(mid, reappeared)

    Fixtures.apply_package_revision!(to, [
      {changed, "3"},
      {reverted, "1"},
      {reappeared, "1"},
      {added, "2"},
      {metadata_only, %{version: "1", description: "new"}}
    ])

    Fixtures.remove_package!(to, removed)
    Fixtures.remove_package!(to, transient)

    page = RevisionComparison.packages(from, to)
    assert page.count == 3
    assert page.counts == %Counts{added: 1, removed: 1, changed: 1}

    assert page.results == [
             %PackageRow{
               attribute: "net.added",
               old_version: nil,
               new_version: "2",
               type: :added
             },
             %PackageRow{
               attribute: "net.changed",
               old_version: "1",
               new_version: "3",
               type: :changed
             },
             %PackageRow{
               attribute: "net.removed",
               old_version: "1",
               new_version: nil,
               type: :removed
             }
           ]

    assert RevisionComparison.packages(from, from) == %Page{}
  end

  test "nil versions do not erase presence changes and compare nulls safely" do
    {from, _mid, to} = revisions()
    removed = Fixtures.package!("null.removed")
    added = Fixtures.package!("null.added")
    changed = Fixtures.package!("null.changed")
    unchanged = Fixtures.package!("null.unchanged")

    Fixtures.apply_package_revision!(from, [
      {removed, %{version: nil}},
      {changed, %{version: nil}},
      {unchanged, %{version: nil}}
    ])

    Fixtures.apply_package_revision!(to, [
      {added, %{version: nil}},
      {changed, "1"},
      {unchanged, %{version: nil}}
    ])

    Fixtures.remove_package!(to, removed)

    page = RevisionComparison.packages(from, to)
    assert page.counts == %Counts{added: 1, removed: 1, changed: 1}

    assert page.results == [
             %PackageRow{
               attribute: "null.added",
               old_version: nil,
               new_version: nil,
               type: :added
             },
             %PackageRow{
               attribute: "null.changed",
               old_version: nil,
               new_version: "1",
               type: :changed
             },
             %PackageRow{
               attribute: "null.removed",
               old_version: nil,
               new_version: nil,
               type: :removed
             }
           ]
  end

  test "package search and type filtering happen before pagination without altering global counts" do
    {from, _mid, to} = revisions()

    added =
      Enum.map(
        1..16,
        &Fixtures.package!("needle.added.#{String.pad_leading(to_string(&1), 2, "0")}")
      )

    removed = Fixtures.package!("needle.removed")
    changed = Fixtures.package!("other.changed")
    Fixtures.apply_package_revision!(from, [{removed, "1"}, {changed, "1"}])
    Fixtures.apply_package_revision!(to, Enum.map(added, &{&1, "1"}) ++ [{changed, "2"}])
    Fixtures.remove_package!(to, removed)

    first = RevisionComparison.packages(from, to, search: "needle", change: "added")
    second = RevisionComparison.packages(from, to, search: "needle", change: "added", page: 2)
    assert first.count == 16
    assert first.total_pages == 2
    assert first.page == 1

    assert Enum.map(first.results, & &1.attribute) ==
             Enum.map(Enum.take(added, 15), & &1.attribute)

    assert second.results == [
             %PackageRow{attribute: "needle.added.16", new_version: "1", type: :added}
           ]

    assert second.page == 2
    assert first.counts == %Counts{added: 16, removed: 1, changed: 1}
    assert second.counts == first.counts

    removed_page = RevisionComparison.packages(from, to, search: "needle", change: "removed")
    assert removed_page.count == 1
    assert [%PackageRow{attribute: "needle.removed", type: :removed}] = removed_page.results
    assert removed_page.counts == first.counts

    empty = RevisionComparison.packages(from, to, search: "absent", page: 9)
    assert empty.results == []
    assert empty.count == 0
    assert empty.page == 1
    assert empty.total_pages == 1
    assert empty.counts == first.counts
  end

  test "exactly fifteen package changes fit one page and out-of-range pages clamp" do
    {from, _mid, to} = revisions()
    packages = Enum.map(1..15, fn _ -> Fixtures.package!() end)
    Fixtures.apply_package_revision!(to, Enum.map(packages, &{&1, "1"}))

    page = RevisionComparison.packages(from, to, page: 2)
    assert page.page == 1
    assert page.total_pages == 1
    assert page.count == 15

    assert Enum.sort(Enum.map(page.results, & &1.attribute)) ==
             Enum.sort(Enum.map(packages, & &1.attribute))
  end

  test "options group all compared metadata changes into one row and ignore untracked fields and reversions" do
    {from, mid, to} = revisions()
    changed = Fixtures.option!("services.changed")
    reverted = Fixtures.option!("services.reverted")
    untracked = Fixtures.option!("services.untracked")
    added = Fixtures.option!("services.added")
    removed = Fixtures.option!("services.removed")
    transient = Fixtures.option!("services.transient")
    old = %{description: "old", type: "bool", default: nil, example: "false", read_only: false}
    new = %{description: "new", type: "str", default: "text", example: nil, read_only: true}

    Fixtures.apply_option_revision!(from, [
      {changed, old},
      {reverted, %{type: "bool"}},
      {untracked, %{loc: ["old"]}},
      {removed, %{type: "bool"}}
    ])

    Fixtures.apply_option_revision!(mid, [
      {changed, %{type: "int"}},
      {reverted, %{type: "str"}},
      {added, %{type: "bool"}},
      {removed, %{type: "str"}},
      {transient, %{type: "bool"}}
    ])

    Fixtures.apply_option_revision!(to, [
      {changed, new},
      {reverted, %{type: "bool"}},
      {untracked, %{loc: ["new"], related_packages: "new"}},
      {added, %{type: "str"}}
    ])

    Fixtures.remove_option!(to, removed)
    Fixtures.remove_option!(to, transient)

    page = RevisionComparison.options(from, to)
    assert page.count == 3
    assert page.counts == %Counts{added: 1, removed: 1, changed: 1}

    assert [
             %OptionRow{name: "services.added", type: :added, fields: []},
             %OptionRow{name: "services.changed", type: :changed, fields: fields},
             %OptionRow{name: "services.removed", type: :removed, fields: []}
           ] = page.results

    assert Map.new(fields, &{&1.field, {&1.old, &1.new}}) == %{
             description: {"old", "new"},
             type: {"bool", "str"},
             default: {nil, "text"},
             example: {"false", nil},
             read_only: {false, true}
           }

    assert Enum.all?(fields, &(&1.option_name == changed.name))
    assert RevisionComparison.options(from, from) == %Page{}
  end

  test "option search and change filtering paginate distinct options, not changed fields" do
    {from, _mid, to} = revisions()

    options =
      Enum.map(
        1..16,
        &Fixtures.option!("services.needle#{String.pad_leading(to_string(&1), 2, "0")}")
      )

    added = Fixtures.option!("services.other")

    Fixtures.apply_option_revision!(
      from,
      Enum.map(options, &{&1, %{type: "bool", description: "old"}})
    )

    Fixtures.apply_option_revision!(
      to,
      Enum.map(options, &{&1, %{type: "str", description: "new"}}) ++ [{added, %{}}]
    )

    first = RevisionComparison.options(from, to, search: "needle", change: "changed")
    second = RevisionComparison.options(from, to, search: "needle", change: "changed", page: 2)
    assert first.count == 16
    assert first.total_pages == 2
    assert Enum.map(first.results, & &1.name) == Enum.map(Enum.take(options, 15), & &1.name)
    assert [%OptionRow{name: "services.needle16", fields: fields}] = second.results

    assert Map.new(fields, &{&1.field, {&1.old, &1.new}}) == %{
             description: {"old", "new"},
             type: {"bool", "str"}
           }

    assert first.counts == %Counts{added: 1, removed: 0, changed: 16}
    assert second.counts == first.counts
  end

  test "comparison endpoints are scoped to their own channels" do
    {from, _mid, _to} = revisions()
    other_channel = Fixtures.channel!()
    to = Fixtures.channel_revision!(other_channel, %{released_at: from.released_at})
    package = Fixtures.package!("cross.package")
    option = Fixtures.option!("cross.option")
    Fixtures.apply_package_revision!(from, [{package, "1"}])
    Fixtures.apply_package_revision!(to, [{package, "2"}])
    Fixtures.apply_option_revision!(from, [{option, %{type: "bool"}}])
    Fixtures.apply_option_revision!(to, [{option, %{type: "str"}}])

    assert [%PackageRow{old_version: "1", new_version: "2", type: :changed}] =
             RevisionComparison.packages(from, to).results

    assert [%OptionRow{type: :changed, fields: [%{field: :type, old: "bool", new: "str"}]}] =
             RevisionComparison.options(from, to).results
  end
end
