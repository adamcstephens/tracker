defmodule Tracker.Accounts.Checks.ActorSubjectEqualsArg do
  @moduledoc "Passes when `AshAuthentication.user_to_subject/1` of the actor equals the named action argument."
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(opts) do
    "AshAuthentication.user_to_subject(actor) == arg(#{inspect(opts[:arg])})"
  end

  @impl Ash.Policy.SimpleCheck
  def match?(nil, _, _), do: false

  def match?(actor, %{query: %Ash.Query{arguments: arguments}}, opts) when is_map(actor) do
    AshAuthentication.user_to_subject(actor) == Map.get(arguments, opts[:arg])
  end

  def match?(_, _, _), do: false
end
