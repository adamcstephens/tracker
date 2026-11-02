defmodule Tracker.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    original_token = Application.fetch_env(:nostrum, :token)

    on_exit(fn ->
      case original_token do
        {:ok, token} -> Application.put_env(:nostrum, :token, token)
        :error -> Application.delete_env(:nostrum, :token)
      end
    end)
  end

  test "starts Discord with the configured Nostrum token" do
    Application.put_env(:nostrum, :token, "configured-token")

    assert Tracker.Application.discord_children() == [
             Nostrum.Application,
             Tracker.Discord.Consumer
           ]
  end

  test "does not start Discord without a token" do
    Application.delete_env(:nostrum, :token)

    assert Tracker.Application.discord_children() == []
  end

  test "does not start Discord with an empty token" do
    Application.put_env(:nostrum, :token, "")

    assert Tracker.Application.discord_children() == []
  end
end
