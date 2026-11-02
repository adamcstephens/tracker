defmodule Tracker.Ingestion.Steps.FinalizeTest do
  use Tracker.DataCase, async: true

  alias Tracker.Fixtures
  alias Tracker.Ingestion.{Pipeline, StepContext}
  alias Tracker.Ingestion.Steps.Finalize
  alias Tracker.Nixpkgs.{ChannelRevision, OptionHistory, RevisionComparison, RevisionSummary}
  alias Tracker.Nixpkgs.RevisionComparison.{Counts, OptionRow, PackageRow, Page}

  test "finalization persists bounded balanced comparisons before publishing completion" do
    channel = Fixtures.channel!()
    from = revision(channel, ~U[2026-04-01 00:00:00Z])
    to = revision(channel, ~U[2026-04-08 00:00:00Z], from)
    changed = Fixtures.package!("summary.changed")
    removed = Fixtures.package!("summary.removed")
    added = Enum.map(1..5, &Fixtures.package!("summary.added#{&1}"))
    option = Fixtures.option!("services.summary")
    option_added = Fixtures.option!("services.summaryAdded")
    option_removed = Fixtures.option!("services.summaryRemoved")

    Fixtures.apply_package_revision!(from, [{changed, "1"}, {removed, "1"}])

    Fixtures.apply_option_revision!(from, [
      {option, %{type: "bool", default: nil, read_only: false}},
      {option_removed, %{type: "bool"}}
    ])

    assert :ok = finalize(from)

    Fixtures.apply_package_revision!(to, [{changed, "2"} | Enum.map(added, &{&1, "1"})])
    Fixtures.remove_package!(to, removed)

    Fixtures.apply_option_revision!(to, [
      {option, %{type: "str", default: "value", read_only: true}},
      {option_added, %{type: "bool"}}
    ])

    Fixtures.remove_option!(to, option_removed)

    expected_packages = RevisionComparison.packages(from, to, preview: true)
    expected_options = RevisionComparison.options(from, to, preview: true)
    Phoenix.PubSub.subscribe(Tracker.PubSub, "channel_revisions:#{channel.id}:completed")
    Phoenix.PubSub.subscribe(Tracker.PubSub, "channel_revisions:#{channel.id}:options_completed")

    assert :ok = finalize(to)
    assert_receive %Ash.Notifier.Notification{action: %{name: :record_result}} = notification
    assert notification.data.package_summary != nil
    assert notification.data.option_summary != nil
    assert_receive %Ash.Notifier.Notification{action: %{name: :record_options_result}}

    stored = ChannelRevision.get_by_id!(to.id)
    assert stored.result == :success
    assert stored.options_result == :success
    assert RevisionSummary.to_page(stored.package_summary) == expected_packages
    assert RevisionSummary.to_page(stored.option_summary) == expected_options

    assert %Page{counts: %Counts{added: 5, removed: 1, changed: 1}, results: rows} =
             RevisionSummary.to_page(stored.package_summary)

    assert length(rows) == 3
    assert Enum.map(rows, & &1.type) == [:changed, :added, :removed]
    assert [%PackageRow{old_version: "1", new_version: "2"} | _] = rows

    assert %Page{results: [%OptionRow{fields: fields} | _]} =
             RevisionSummary.to_page(stored.option_summary)

    assert Enum.all?(fields, &match?(%OptionHistory.MetadataDiff{}, &1))

    assert Map.new(fields, &{&1.field, {&1.old, &1.new}}) == %{
             type: {"bool", "str"},
             default: {nil, "value"},
             read_only: {false, true}
           }
  end

  test "first revisions finish successfully without treating their inventory as added" do
    current = revision(Fixtures.channel!(), ~U[2026-04-01 00:00:00Z])
    Fixtures.apply_package_revision!(current, [{Fixtures.package!(), "1"}])
    Fixtures.apply_option_revision!(current, [{Fixtures.option!(), %{type: "bool"}}])

    assert :ok = finalize(current)
    stored = ChannelRevision.get_by_id!(current.id)
    assert stored.result == :success
    assert stored.options_result == :success
    assert stored.package_summary == nil
    assert stored.option_summary == nil
  end

  test "nixpkgs finalization persists packages but never an option comparison" do
    channel = Fixtures.channel!("nixpkgs-summary-#{System.unique_integer([:positive])}")
    from = revision(channel, ~U[2026-04-01 00:00:00Z])
    to = revision(channel, ~U[2026-04-08 00:00:00Z], from)
    assert :ok = finalize(from, [:load_packages])
    Fixtures.apply_package_revision!(to, [{Fixtures.package!(), "1"}])
    assert :ok = finalize(to, [:load_packages])

    stored = ChannelRevision.get_by_id!(to.id)
    assert stored.result == :success
    assert stored.options_result == nil
    assert stored.option_summary == nil
    assert %Page{counts: %Counts{added: 1}} = RevisionSummary.to_page(stored.package_summary)
  end

  test "predecessor package readiness does not prevent independently ready option summaries" do
    channel = Fixtures.channel!()
    from = revision(channel, ~U[2026-04-01 00:00:00Z])
    to = revision(channel, ~U[2026-04-08 00:00:00Z], from)
    ChannelRevision.record_options_result!(from, %{options_result: :success})
    Fixtures.apply_package_revision!(to, [{Fixtures.package!(), "1"}])
    Fixtures.apply_option_revision!(to, [{Fixtures.option!(), %{type: "bool"}}])

    assert :ok = finalize(to)
    stored = ChannelRevision.get_by_id!(to.id)
    assert stored.result == :success
    assert stored.options_result == :success
    assert stored.package_summary == nil
    assert %Page{counts: %Counts{added: 1}} = RevisionSummary.to_page(stored.option_summary)
  end

  test "unsuccessful predecessor options leave options unavailable without hiding ready packages" do
    for options_result <- [nil, :error] do
      channel = Fixtures.channel!()
      from = revision(channel, ~U[2026-04-01 00:00:00Z])
      to = revision(channel, ~U[2026-04-08 00:00:00Z], from)
      ChannelRevision.record_result!(from, %{result: :success})

      if options_result,
        do: ChannelRevision.record_options_result!(from, %{options_result: options_result})

      assert :ok = finalize(to)
      stored = ChannelRevision.get_by_id!(to.id)
      assert stored.option_summary == nil
      assert RevisionSummary.to_page(stored.package_summary) == %Page{}
    end
  end

  test "partial and failed predecessor package loads are not summarized as complete" do
    for result <- [nil, :partial_success, :error] do
      channel = Fixtures.channel!()
      from = revision(channel, ~U[2026-04-01 00:00:00Z])
      to = revision(channel, ~U[2026-04-08 00:00:00Z], from)
      if result, do: ChannelRevision.record_result!(from, %{result: result})

      assert :ok = finalize(to)
      stored = ChannelRevision.get_by_id!(to.id)
      assert stored.result == :success
      assert stored.package_summary == nil
      assert stored.option_summary == nil
    end
  end

  test "summary persistence requires both endpoint ingestion results independently" do
    channel = Fixtures.channel!()
    from = revision(channel, ~U[2026-04-01 00:00:00Z])
    to = revision(channel, ~U[2026-04-08 00:00:00Z], from)
    assert :ok = finalize(from)
    to = ChannelRevision.record_result!(to, %{result: :success})

    assert {:ok, stored} = RevisionSummary.persist(to)
    assert RevisionSummary.to_page(stored.package_summary) == %Page{}
    assert stored.option_summary == nil
  end

  defp revision(channel, at, previous \\ nil) do
    Fixtures.channel_revision!(channel, %{
      released_at: at,
      previous_channel_revision_id: get_in(previous.id)
    })
  end

  defp finalize(revision, steps \\ [:load_packages, :load_options]) do
    Finalize.run(%StepContext{
      pipeline: %Pipeline{active_steps: steps},
      channel_revision: revision
    })
  end
end
