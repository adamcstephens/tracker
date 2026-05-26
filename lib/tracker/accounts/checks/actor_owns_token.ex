defmodule Tracker.Accounts.Checks.ActorOwnsToken do
  @moduledoc "Passes when the actor's user-subject string equals the token row's `subject`."
  use Ash.Policy.SimpleCheck

  alias Tracker.Accounts.User

  @impl Ash.Policy.Check
  def describe(_opts), do: "actor owns token"

  @impl Ash.Policy.SimpleCheck
  def match?(nil, _, _), do: false

  def match?(%User{} = actor, %{changeset: %Ash.Changeset{data: %{subject: subject}}}, _opts)
      when is_binary(subject) do
    AshAuthentication.user_to_subject(actor) == subject
  end

  def match?(_, _, _), do: false
end
