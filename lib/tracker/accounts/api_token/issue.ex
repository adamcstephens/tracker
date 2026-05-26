defmodule Tracker.Accounts.ApiToken.Issue do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias AshAuthentication.Jwt
  alias Tracker.Accounts.ApiToken

  @one_year_seconds 365 * 24 * 60 * 60

  @impl Ash.Resource.Actions.Implementation
  def run(input, _opts, %{actor: actor}) do
    subject_user_id = input.arguments.subject_user_id
    expires_in = Map.get(input.arguments, :expires_in) || @one_year_seconds
    label = Map.get(input.arguments, :label)
    user_mod = Module.concat([Tracker, Accounts, User])

    with {:ok, subject_user} <- Ash.get(user_mod, subject_user_id, authorize?: false),
         {:ok, jwt, claims} <- mint(subject_user, expires_in, user_mod),
         {:ok, _record} <- store(claims, subject_user_id, actor, label) do
      {:ok,
       %{
         token: ApiToken.token_prefix() <> jwt,
         jti: claims["jti"],
         expires_at: DateTime.from_unix!(trunc(claims["exp"]))
       }}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, "failed to mint api token"}
    end
  end

  defp mint(subject_user, expires_in_seconds, user_mod) do
    opts = [token_lifetime: expires_in_seconds]
    default_claims = Jwt.Config.default_claims(user_mod, opts)
    signer = Jwt.Config.token_signer(user_mod, opts)

    extra_claims = %{
      "sub" => AshAuthentication.user_to_subject(subject_user),
      "purpose" => "api"
    }

    Joken.generate_and_sign(default_claims, extra_claims, signer)
  end

  defp store(claims, subject_user_id, actor, label) do
    Tracker.Accounts.ApiToken
    |> Ash.Changeset.for_create(:create_internal, %{
      jti: claims["jti"],
      label: label,
      expires_at: DateTime.from_unix!(trunc(claims["exp"])),
      subject_user_id: subject_user_id,
      issued_by_user_id: actor.id
    })
    |> Ash.create(authorize?: false)
  end
end
