defmodule Tracker.Accounts.Checks.AdminRevokingServiceAccountToken do
  @moduledoc """
  Passes when the actor is an admin AND the token row's `subject` resolves
  to a service-account user (i.e. `github_id` is nil).
  """
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_opts), do: "actor is :admin and token belongs to a service account"

  @impl Ash.Policy.SimpleCheck
  def match?(nil, _, _), do: false

  def match?(
        %{roles: roles},
        %{changeset: %Ash.Changeset{data: %{subject: subject}}},
        _opts
      )
      when is_list(roles) and is_binary(subject) do
    :admin in roles and service_account_subject?(subject)
  end

  def match?(_, _, _), do: false

  defp service_account_subject?(subject) do
    user_mod = Module.concat([Tracker, Accounts, User])

    case AshAuthentication.subject_to_user(subject, user_mod, authorize?: false) do
      {:ok, %{github_id: nil}} -> true
      _ -> false
    end
  end
end
