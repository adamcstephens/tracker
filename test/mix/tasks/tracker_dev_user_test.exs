defmodule Mix.Tasks.Tracker.DevUserTest do
  use Tracker.DataCase, async: false

  alias Mix.Tasks.Tracker.DevUser
  alias Tracker.Accounts.User

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
    test "defaults the username" do
      assert DevUser.Create.parse!([])[:username] == "devuser"
    end

    test "takes an explicit username and the admin flag" do
      opts = DevUser.Create.parse!(["--username", "alice", "--admin"])

      assert opts[:username] == "alice"
      assert opts[:admin]
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
      assert_received {:mix_shell, :info, [message]}
      assert message =~ "/dev/login/#{token}"
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
  end
end
