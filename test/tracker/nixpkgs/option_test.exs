defmodule Tracker.Nixpkgs.OptionTest do
  use Tracker.DataCase, async: true

  alias Tracker.Fixtures
  alias Tracker.Nixpkgs.Option

  describe "prefix_counts_by_change_and_channel_revision/2" do
    # The full prefix-folding behaviour maps a change's touched files to the
    # options those files declare — option↔file membership, reinstated on option
    # file spans in trk-323 (P4). Until then this read is deferred to [].
    test "is deferred to the option-files vertical (returns [])" do
      change = Fixtures.change!()
      cr = Fixtures.channel_revision!()

      assert Option.prefix_counts_by_change_and_channel_revision(change.id, cr.id) == []
    end
  end
end
