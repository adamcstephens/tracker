defmodule Tracker.Accounts.Checks.AdminListingServiceAccountTokens do
  @moduledoc """
  Passes when the actor is an admin AND the named subject argument resolves
  to a service-account user (`github_id` is nil).
  """
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(opts) do
    "actor is :admin and arg(#{inspect(opts[:arg])}) refers to a service account"
  end

  @impl Ash.Policy.SimpleCheck
  def match?(nil, _, _), do: false

  def match?(%{roles: roles}, %{query: %Ash.Query{arguments: arguments}}, opts)
      when is_list(roles) do
    :admin in roles and service_account_subject?(Map.get(arguments, opts[:arg]))
  end

  def match?(_, _, _), do: false

  defp service_account_subject?(subject) when is_binary(subject) do
    user_mod = Module.concat([Tracker, Accounts, User])

    case AshAuthentication.subject_to_user(subject, user_mod, authorize?: false) do
      {:ok, %{github_id: nil}} -> true
      _ -> false
    end
  end

  defp service_account_subject?(_), do: false
end
