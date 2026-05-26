defmodule Tracker.Accounts.User.IssueApiToken do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias AshAuthentication.Jwt
  alias Tracker.Accounts.{Token, User}

  @one_year_seconds 365 * 24 * 60 * 60

  @impl Ash.Resource.Actions.Implementation
  def run(input, _opts, _context) do
    subject_id = input.arguments.subject_id
    expires_in = Map.get(input.arguments, :expires_in) || @one_year_seconds
    label = Map.get(input.arguments, :label)

    with {:ok, user} <- Ash.get(User, subject_id, authorize?: false),
         {:ok, token, claims} <- mint(user, expires_in),
         {:ok, _record} <- store(token, label) do
      {:ok,
       %{
         token: token,
         jti: claims["jti"],
         expires_at: DateTime.from_unix!(trunc(claims["exp"]))
       }}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, "failed to mint api token"}
    end
  end

  defp mint(user, expires_in_seconds) do
    opts = [token_lifetime: expires_in_seconds]
    default_claims = Jwt.Config.default_claims(User, opts)
    signer = Jwt.Config.token_signer(User, opts)

    extra_claims = %{
      "sub" => AshAuthentication.user_to_subject(user),
      "purpose" => "api"
    }

    Joken.generate_and_sign(default_claims, extra_claims, signer)
  end

  defp store(token, label) do
    extra_data = if label, do: %{"label" => label}, else: %{}

    Token
    |> Ash.Changeset.for_create(:store_token, %{
      "token" => token,
      "purpose" => "api",
      "extra_data" => extra_data
    })
    |> Ash.create(authorize?: false)
  end
end
