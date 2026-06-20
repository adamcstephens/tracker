defmodule TrackerWeb.NotificationPresenterTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Notifications.Notification
  alias TrackerWeb.NotificationPresenter

  # Round-trips through the ledger so the references are loaded exactly as the
  # inbox and feed see them.
  defp loaded_notification!(user, overrides) do
    notification!(user, overrides)
    [n] = Notification.for_user!(actor: user)
    n
  end

  test "change_propagated names the change and its destination branch" do
    user = register_user!()
    change = change!()
    chan = channel!("nixos-unstable")
    rev = channel_revision!(chan)
    branch = change_branch!(change, "nixos-unstable", rev)

    n =
      loaded_notification!(user, %{
        type: :change_propagated,
        change_id: change.id,
        change_branch_id: branch.id,
        channel_id: chan.id,
        channel_revision_id: rev.id
      })

    text = NotificationPresenter.describe(n)
    assert text =~ "PR ##{change.number}"
    assert text =~ change.title
    assert text =~ "reached nixos-unstable"
  end

  test "change_propagated to an intermediate branch still names where it went" do
    user = register_user!()
    change = change!()
    branch = change_branch!(change, "staging-next")

    n =
      loaded_notification!(user, %{
        type: :change_propagated,
        change_id: change.id,
        change_branch_id: branch.id
      })

    assert NotificationPresenter.describe(n) =~ "reached staging-next"
  end

  test "channel_revision_published includes the short revision hash" do
    user = register_user!()
    chan = channel!("nixos-unstable")
    rev = channel_revision!(chan)

    n =
      loaded_notification!(user, %{
        type: :channel_revision_published,
        channel_id: chan.id,
        channel_revision_id: rev.id
      })

    text = NotificationPresenter.describe(n)
    assert text =~ String.slice(rev.revision, 0, 7)
    assert text =~ "published on nixos-unstable"
  end

  describe "hero/1" do
    test "package notifications lead with the package attribute" do
      user = register_user!()
      pkg = package!("ripgrep")
      chan = channel!()

      n =
        loaded_notification!(user, %{
          type: :package_version_changed,
          package_id: pkg.id,
          channel_id: chan.id
        })

      assert NotificationPresenter.hero(n) == "ripgrep"
    end

    test "revision notifications lead with the short hash" do
      user = register_user!()
      chan = channel!()
      rev = channel_revision!(chan)

      n =
        loaded_notification!(user, %{
          type: :channel_revision_published,
          channel_id: chan.id,
          channel_revision_id: rev.id
        })

      assert NotificationPresenter.hero(n) == "New revision #{String.slice(rev.revision, 0, 7)}"
    end

    test "propagations lead with the change title verbatim" do
      user = register_user!()
      change = change!()
      branch = change_branch!(change, "master")

      n =
        loaded_notification!(user, %{
          type: :change_propagated,
          change_id: change.id,
          change_branch_id: branch.id
        })

      assert NotificationPresenter.hero(n) == change.title
    end
  end

  describe "version changes" do
    defp version_bump!(user, attribute, old_version, new_version) do
      pkg = package!(attribute)
      chan = channel!()
      prev = channel_revision!(chan, %{released_at: ~U[2026-02-01 00:00:00Z]})

      rev =
        channel_revision!(chan, %{
          previous_channel_revision_id: prev.id,
          released_at: ~U[2026-02-02 00:00:00Z]
        })

      apply_package_revision!(prev, [{pkg, old_version}])
      apply_package_revision!(rev, [{pkg, new_version}])

      notification!(user, %{
        type: :package_version_changed,
        package_id: pkg.id,
        channel_id: chan.id,
        channel_revision_id: rev.id
      })
    end

    test "version_changes/1 resolves old and new versions per notification" do
      user = register_user!()
      vim = version_bump!(user, "vim", "9.0", "9.1")
      rg = version_bump!(user, "ripgrep", "14.0.3", "14.1.0")
      notifications = Notification.for_user!(actor: user)

      changes = NotificationPresenter.version_changes(notifications)

      assert changes[vim.id] == {"9.0", "9.1"}
      assert changes[rg.id] == {"14.0.3", "14.1.0"}
    end

    test "version_changes/1 skips notifications it cannot resolve" do
      user = register_user!()
      pkg = package!()
      chan = channel!()
      # no predecessor revision recorded
      rev = channel_revision!(chan)
      apply_package_revision!(rev, [{pkg, "2.0"}])

      notification!(user, %{
        type: :package_version_changed,
        package_id: pkg.id,
        channel_id: chan.id,
        channel_revision_id: rev.id
      })

      notifications = Notification.for_user!(actor: user)

      assert NotificationPresenter.version_changes(notifications) == %{}
    end

    test "hero/2 and describe/2 render the bump, falling back without one" do
      user = register_user!()
      chan = channel!("nixos-unstable")
      pkg = package!("vim")

      n =
        loaded_notification!(user, %{
          type: :package_version_changed,
          package_id: pkg.id,
          channel_id: chan.id
        })

      changes = %{n.id => {"9.0", "9.1"}}

      assert NotificationPresenter.hero(n, changes) == "vim 9.0 → 9.1"
      assert NotificationPresenter.describe(n, changes) == "vim 9.0 → 9.1 on nixos-unstable"

      assert NotificationPresenter.hero(n, %{}) == "vim"
      assert NotificationPresenter.describe(n, %{}) == "vim updated on nixos-unstable"
    end

    test "hero/2 and describe/2 ignore the map for other types" do
      user = register_user!()
      chan = channel!("nixos-unstable")
      pkg = package!("vim")

      n =
        loaded_notification!(user, %{
          type: :package_added,
          package_id: pkg.id,
          channel_id: chan.id
        })

      changes = %{n.id => {"9.0", "9.1"}}

      assert NotificationPresenter.hero(n, changes) == "vim"
      assert NotificationPresenter.describe(n, changes) == "vim added to nixos-unstable"
    end
  end

  describe "type metadata" do
    test "labels and css classes per type" do
      assert NotificationPresenter.type_label(:package_version_changed) == "Updated"
      assert NotificationPresenter.type_filter_label(:package_version_changed) == "Updates"
      assert NotificationPresenter.type_class(:package_version_changed) == "update"
      assert NotificationPresenter.type_label(:change_propagated) == "Propagated"
      assert NotificationPresenter.type_class(:channel_revision_published) == "revision"
    end

    test "type_order/0 lists all five types" do
      assert NotificationPresenter.type_order() == [
               :package_version_changed,
               :change_propagated,
               :package_added,
               :package_removed,
               :channel_revision_published
             ]
    end
  end

  describe "time helpers" do
    @now ~U[2026-06-10 12:00:00Z]

    test "relative_time/2" do
      assert NotificationPresenter.relative_time(~U[2026-06-10 11:59:40Z], @now) == "just now"
      assert NotificationPresenter.relative_time(~U[2026-06-10 11:53:00Z], @now) == "7m ago"
      assert NotificationPresenter.relative_time(~U[2026-06-10 10:00:00Z], @now) == "2h ago"
      assert NotificationPresenter.relative_time(~U[2026-06-08 12:00:00Z], @now) == "2d ago"
    end

    test "day_bucket/2" do
      assert NotificationPresenter.day_bucket(~U[2026-06-10 00:01:00Z], @now) == "Today"
      assert NotificationPresenter.day_bucket(~U[2026-06-09 23:59:00Z], @now) == "Yesterday"
      assert NotificationPresenter.day_bucket(~U[2026-06-05 09:00:00Z], @now) == "Friday, Jun 5"
    end
  end
end
