defmodule Tracker.Accounts.Checks.ActorIdEqualsArg do
  @moduledoc "Passes when the actor's id equals the named action argument."
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(opts) do
    "actor.id == arg(#{inspect(opts[:arg])})"
  end

  @impl Ash.Policy.SimpleCheck
  def match?(nil, _, _), do: false

  def match?(%{id: actor_id}, %{action_input: %{arguments: arguments}}, opts) do
    actor_id == Map.get(arguments, opts[:arg])
  end

  def match?(%{id: actor_id}, %{query: %Ash.Query{arguments: arguments}}, opts) do
    actor_id == Map.get(arguments, opts[:arg])
  end

  def match?(_, _, _), do: false
end
