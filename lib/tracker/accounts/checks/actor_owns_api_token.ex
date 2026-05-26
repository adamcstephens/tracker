defmodule Tracker.Accounts.Checks.ActorOwnsApiToken do
  @moduledoc "Passes when the actor's id equals the ApiToken row's `subject_user_id`."
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_opts), do: "actor.id == api_token.subject_user_id"

  @impl Ash.Policy.SimpleCheck
  def match?(nil, _, _), do: false

  def match?(%{id: actor_id}, %{changeset: %Ash.Changeset{data: %{subject_user_id: id}}}, _opts) do
    actor_id == id
  end

  def match?(_, _, _), do: false
end
