defmodule Mix.Tasks.Tracker.DevUserTest do
  use Tracker.DataCase, async: false

  import Tracker.Fixtures

  alias Mix.Tasks.Tracker.DevUser
  alias Tracker.Accounts.User
  alias Tracker.Notifications.ChangeSubscription
  alias Tracker.Notifications.ChannelSubscription
  alias Tracker.Notifications.Notification
  alias Tracker.Notifications.PackageSubscription

  setup do
    path = Path.join(System.tmp_dir!(), "dev-login-#{System.unique_integer([:positive])}.json")
    Application.put_env(:tracker, :dev_login_file, path)
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      File.rm(path)
      Application.delete_env(:tracker, :dev_login_file)
      Mix.shell(shell)
    end)

    :ok
  end

  describe "Create.parse!/1" do
    test "defaults the username and notification count" do
      opts = DevUser.Create.parse!([])

      assert opts[:username] == "devuser"
      assert opts[:notifications] == 12
    end

    test "takes an explicit username, the admin flag and a notification count" do
      opts = DevUser.Create.parse!(["--username", "alice", "--admin", "--notifications", "3"])

      assert opts[:username] == "alice"
      assert opts[:admin]
      assert opts[:notifications] == 3
    end
  end

  describe "run/1" do
    test "creates a plain user and mints a token that authenticates as them" do
      DevUser.Create.run(["--username", "devuser"])

      user = User.get_by_github_username!("devuser", authorize?: false)
      refute User.has_role?(user, :admin)

      token = Jason.decode!(File.read!(Tracker.DevLogin.path()))["token"]

      assert {:ok, authenticated} = Tracker.DevLogin.authenticate(token)
      assert authenticated.id == user.id
      assert shell_output() =~ "/dev/login/#{token}"
    end

    test "--admin grants the admin role" do
      DevUser.Create.run(["--username", "devadmin", "--admin"])

      user = User.get_by_github_username!("devadmin", authorize?: false)

      assert User.has_role?(user, :admin)
    end

    test "re-running rotates the token without duplicating the user" do
      DevUser.Create.run(["--username", "devuser"])
      first = Jason.decode!(File.read!(Tracker.DevLogin.path()))["token"]

      DevUser.Create.run(["--username", "devuser"])
      second = Jason.decode!(File.read!(Tracker.DevLogin.path()))["token"]

      refute first == second
      assert :error = Tracker.DevLogin.authenticate(first)
      assert {:ok, user} = Tracker.DevLogin.authenticate(second)
      assert user.id == User.get_by_github_username!("devuser", authorize?: false).id
    end

    test "says so when there is nothing ingested to seed from" do
      DevUser.Create.run(["--username", "devuser"])

      assert shell_output() =~ "No ingested channel data"
      assert Notification.for_user!(actor: dev_user()) == []
    end
  end

  describe "run/1 with ingested data" do
    setup do
      now = DateTime.utc_now(:second)
      channel = channel!("nixos-unstable")
      older = channel_revision!(channel, %{released_at: DateTime.add(now, -3, :day)})

      newer =
        channel_revision!(channel, %{
          released_at: DateTime.add(now, -1, :day),
          previous_channel_revision_id: older.id
        })

      [bumped, steady, dropped, introduced] = for _ <- 1..4, do: package!()
      apply_package_revision!(older, [{bumped, "1.0"}, {steady, "1.0"}, {dropped, "1.0"}])
      apply_package_revision!(newer, [{bumped, "1.1"}, {steady, "1.0"}, {introduced, "2.0"}])
      remove_package!(newer, dropped)

      change = change!()
      change_branch!(change, channel.name, newer)

      %{channel: channel}
    end

    test "subscribes the dev user to the packages it notified about, the channel and a change" do
      DevUser.Create.run(["--username", "devuser", "--notifications", "6"])

      user = dev_user()

      assert length(PackageSubscription.for_user!(actor: user)) == 3
      assert [_channel_subscription] = ChannelSubscription.for_user!(actor: user)
      assert [_change_subscription] = ChangeSubscription.for_user!(actor: user)
    end

    test "seeds back-dated notifications for what actually happened in the revision" do
      DevUser.Create.run(["--username", "devuser", "--notifications", "6"])

      notifications = Notification.for_user!(actor: dev_user())
      types = Enum.map(notifications, & &1.type)
      now = DateTime.utc_now()

      assert length(notifications) == 6
      assert :channel_revision_published in types
      assert :change_propagated in types
      assert :package_version_changed in types
      assert :package_added in types
      assert :package_removed in types
      assert :package_change_merged in types
      assert Enum.all?(notifications, &(DateTime.compare(&1.occurred_at, now) == :lt))
    end

    test "leaves the oldest third read so both inbox tabs have rows" do
      DevUser.Create.run(["--username", "devuser", "--notifications", "6"])

      notifications = Notification.for_user!(actor: dev_user())

      assert Enum.count(notifications, & &1.read_at) == 2
    end

    test "re-running does not duplicate the seeded notifications" do
      DevUser.Create.run(["--username", "devuser", "--notifications", "6"])
      DevUser.Create.run(["--username", "devuser", "--notifications", "6"])

      assert length(Notification.for_user!(actor: dev_user())) == 6
    end

    test "--notifications 0 skips seeding entirely" do
      DevUser.Create.run(["--username", "devuser", "--notifications", "0"])

      user = dev_user()

      assert Notification.for_user!(actor: user) == []
      assert PackageSubscription.for_user!(actor: user) == []
    end
  end

  defp dev_user, do: User.get_by_github_username!("devuser", authorize?: false)

  defp shell_output do
    receive do
      {:mix_shell, :info, [message]} -> message <> "\n" <> shell_output()
    after
      0 -> ""
    end
  end
end
