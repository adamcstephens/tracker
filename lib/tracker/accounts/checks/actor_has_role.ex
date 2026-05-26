defmodule Tracker.Accounts.Checks.ActorHasRole do
  @moduledoc "Passes when the actor's `:roles` list contains the configured role."
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(opts) do
    "actor has role #{inspect(opts[:role])}"
  end

  @impl Ash.Policy.SimpleCheck
  def match?(nil, _, _), do: false

  def match?(%{roles: roles}, _context, opts) when is_list(roles) do
    opts[:role] in roles
  end

  def match?(_, _, _), do: false
end
