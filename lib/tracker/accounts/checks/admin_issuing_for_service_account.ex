defmodule Tracker.Accounts.Checks.AdminIssuingForServiceAccount do
  @moduledoc """
  Passes when the actor is an admin AND the argument named by `:arg`
  refers to a service-account user (i.e. `github_id` is nil).
  """
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(opts) do
    "actor is :admin and arg(#{inspect(opts[:arg])}) is a service account"
  end

  @impl Ash.Policy.SimpleCheck
  def match?(nil, _, _), do: false

  def match?(%{roles: roles}, %{action_input: %{arguments: arguments}}, opts)
      when is_list(roles) do
    :admin in roles and service_account?(Map.get(arguments, opts[:arg]))
  end

  def match?(_, _, _), do: false

  defp service_account?(nil), do: false

  defp service_account?(user_id) when is_binary(user_id) do
    user_mod = Module.concat([Tracker, Accounts, User])

    case Ash.get(user_mod, user_id, authorize?: false) do
      {:ok, %{github_id: nil}} -> true
      _ -> false
    end
  end
end
