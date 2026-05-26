defmodule Tracker.Accounts.Checks.AdminRevokingServiceAccountApiToken do
  @moduledoc """
  Passes when the actor is an admin AND the ApiToken row's `subject_user`
  is a service account (i.e. its `github_id` is nil).
  """
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_opts), do: "actor is :admin and api_token belongs to a service account"

  @impl Ash.Policy.SimpleCheck
  def match?(nil, _, _), do: false

  def match?(
        %{roles: roles},
        %{changeset: %Ash.Changeset{data: %{subject_user_id: subject_user_id}}},
        _opts
      )
      when is_list(roles) and is_binary(subject_user_id) do
    :admin in roles and service_account?(subject_user_id)
  end

  def match?(_, _, _), do: false

  defp service_account?(user_id) do
    user_mod = Module.concat([Tracker, Accounts, User])

    case Ash.get(user_mod, user_id, authorize?: false) do
      {:ok, %{github_id: nil}} -> true
      _ -> false
    end
  end
end
