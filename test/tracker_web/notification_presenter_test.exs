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
end
