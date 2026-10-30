defmodule Tracker.Accounts.UserIdentityTest do
  use ExUnit.Case, async: true

  test "has a single primary read action" do
    actions = Ash.Resource.Info.actions(Tracker.Accounts.UserIdentity)
    read_actions = Enum.filter(actions, &(&1.name == :read))

    assert [%Ash.Resource.Actions.Read{primary?: true}] = read_actions
    assert Enum.uniq_by(actions, & &1.name) == actions
  end
end
