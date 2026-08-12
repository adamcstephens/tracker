defmodule Tracker.Notifications.NotificationFanoutChangeWorkerTest do
  use Tracker.DataCase, async: true

  import Tracker.Fixtures

  alias Tracker.Nixpkgs.ChangePackage
  alias Tracker.Notifications.{Notification, PackageSubscription}
  alias Tracker.Notifications.NotificationFanoutChangeWorker, as: Worker

  defp linked_change!(package, attrs) do
    change =
      change!(
        nil,
        Map.merge(
          %{
            state: :open,
            base_ref: "master",
            gh_created_at: ~U[2026-03-01 00:00:00Z]
          },
          attrs
        )
      )

    ChangePackage.load!(%{change_id: change.id, package_id: package.id, type: :changed})
    change
  end

  defp subscribe!(user, package, events, channel_id \\ nil) do
    {:ok, sub} = PackageSubscription.subscribe(package.id, channel_id, actor: user)
    {:ok, sub} = PackageSubscription.set_events(sub, events, actor: user)
    sub
  end

  describe "event derivation" do
    test "an open change notifies subscribers who selected change_opened" do
      user = register_user!()
      pkg = package!()
      change = linked_change!(pkg, %{state: :open})
      subscribe!(user, pkg, [:package_change_opened])

      assert :ok = Worker.run(change_id: change.id)

      assert [n] = Notification.for_user!(actor: user)
      assert n.type == :package_change_opened
      assert n.package_id == pkg.id
      assert n.change_id == change.id
      assert n.occurred_at == ~U[2026-03-01 00:00:00Z]
    end

    test "a draft change counts as opened" do
      user = register_user!()
      pkg = package!()
      change = linked_change!(pkg, %{state: :draft})
      subscribe!(user, pkg, [:package_change_opened])

      assert :ok = Worker.run(change_id: change.id)
      assert [%{type: :package_change_opened}] = Notification.for_user!(actor: user)
    end

    test "a merged change notifies subscribers who selected change_merged" do
      user = register_user!()
      pkg = package!()

      change =
        linked_change!(pkg, %{state: :merged, merged_at: ~U[2026-03-02 00:00:00Z]})

      subscribe!(user, pkg, [:package_change_merged])

      assert :ok = Worker.run(change_id: change.id)

      assert [n] = Notification.for_user!(actor: user)
      assert n.type == :package_change_merged
      assert n.occurred_at == ~U[2026-03-02 00:00:00Z]
    end

    test "a closed change notifies nobody" do
      user = register_user!()
      pkg = package!()
      change = linked_change!(pkg, %{state: :closed})
      subscribe!(user, pkg, [:package_change_opened, :package_change_merged])

      assert :ok = Worker.run(change_id: change.id)
      assert [] = Notification.for_user!(actor: user)
    end
  end

  describe "event selection" do
    test "the default subscription selects no change events" do
      user = register_user!()
      pkg = package!()
      change = linked_change!(pkg, %{state: :open})
      {:ok, _} = PackageSubscription.subscribe(pkg.id, nil, actor: user)

      assert :ok = Worker.run(change_id: change.id)
      assert [] = Notification.for_user!(actor: user)
    end

    test "opened and merged are selected independently" do
      user = register_user!()
      pkg = package!()
      change = linked_change!(pkg, %{state: :open})
      subscribe!(user, pkg, [:package_change_merged])

      assert :ok = Worker.run(change_id: change.id)
      assert [] = Notification.for_user!(actor: user)
    end

    test "only packages linked to the change are notified" do
      user = register_user!()
      pkg = package!()
      other = package!()
      change = linked_change!(pkg, %{state: :open})
      subscribe!(user, other, [:package_change_opened])

      assert :ok = Worker.run(change_id: change.id)
      assert [] = Notification.for_user!(actor: user)
    end
  end

  describe "channel scope" do
    test "a stable-scoped subscription is notified by a backport PR" do
      user = register_user!()
      pkg = package!()
      stable = channel!("nixos-25.05")
      change = linked_change!(pkg, %{state: :open, base_ref: "release-25.05"})
      subscribe!(user, pkg, [:package_change_opened], stable.id)

      assert :ok = Worker.run(change_id: change.id)

      assert [n] = Notification.for_user!(actor: user)
      assert n.channel_id == stable.id
    end

    test "a stable-scoped subscription ignores a master PR" do
      user = register_user!()
      pkg = package!()
      stable = channel!("nixos-25.05")
      change = linked_change!(pkg, %{state: :open, base_ref: "master"})
      subscribe!(user, pkg, [:package_change_opened], stable.id)

      assert :ok = Worker.run(change_id: change.id)
      assert [] = Notification.for_user!(actor: user)
    end

    test "an unstable-scoped subscription is notified by a master PR" do
      user = register_user!()
      pkg = package!()
      unstable = channel!("nixos-unstable")
      change = linked_change!(pkg, %{state: :open, base_ref: "master"})
      subscribe!(user, pkg, [:package_change_opened], unstable.id)

      assert :ok = Worker.run(change_id: change.id)
      assert [%{type: :package_change_opened}] = Notification.for_user!(actor: user)
    end

    test "an all-channels subscription is notified regardless of base ref" do
      user = register_user!()
      pkg = package!()
      change = linked_change!(pkg, %{state: :open, base_ref: "release-25.05"})
      subscribe!(user, pkg, [:package_change_opened])

      assert :ok = Worker.run(change_id: change.id)

      assert [n] = Notification.for_user!(actor: user)
      assert n.channel_id == nil
    end

    test "a base ref outside the propagation graph reaches only all-channels subscriptions" do
      scoped_user = register_user!()
      all_user = register_user!()
      pkg = package!()
      stable = channel!("nixos-25.05")
      change = linked_change!(pkg, %{state: :open, base_ref: "some-feature-branch"})
      subscribe!(scoped_user, pkg, [:package_change_opened], stable.id)
      subscribe!(all_user, pkg, [:package_change_opened])

      assert :ok = Worker.run(change_id: change.id)

      assert [] = Notification.for_user!(actor: scoped_user)
      assert [_] = Notification.for_user!(actor: all_user)
    end
  end

  describe "idempotency" do
    test "re-running produces no duplicates" do
      user = register_user!()
      pkg = package!()
      change = linked_change!(pkg, %{state: :open})
      subscribe!(user, pkg, [:package_change_opened])

      assert :ok = Worker.run(change_id: change.id)
      assert :ok = Worker.run(change_id: change.id)
      assert :ok = Worker.run(change_id: change.id)

      assert length(Notification.for_user!(actor: user)) == 1
    end

    test "the same change merging later yields a distinct notification" do
      user = register_user!()
      pkg = package!()
      change = linked_change!(pkg, %{state: :open})
      subscribe!(user, pkg, [:package_change_opened, :package_change_merged])

      assert :ok = Worker.run(change_id: change.id)

      merged =
        change!(change.number, %{state: :merged, merged_at: ~U[2026-03-02 00:00:00Z]})

      assert :ok = Worker.run(change_id: merged.id)

      assert [:package_change_merged, :package_change_opened] =
               Notification.for_user!(actor: user) |> Enum.map(& &1.type) |> Enum.sort()
    end
  end
end
