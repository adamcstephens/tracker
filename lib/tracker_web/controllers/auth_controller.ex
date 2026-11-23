defmodule TrackerWeb.AuthController do
  use TrackerWeb, :controller
  use AshAuthentication.Phoenix.Controller

  require Logger

  def success(conn, activity, user, _token) do
    return_to = get_session(conn, :return_to) || ~p"/"

    conn =
      conn
      |> delete_session(:return_to)
      |> store_in_session(user)
      # If your resource has a different name, update the assign name here (i.e :current_admin)
      |> assign(:current_user, user)

    case activity do
      {:confirm_new_user, :confirm} ->
        conn
        |> put_flash(:info, "Your email address has now been confirmed")
        |> redirect(to: return_to)

      {:password, :reset} ->
        conn
        |> put_flash(:info, "Your password has successfully been reset")
        |> redirect(to: return_to)

      _ ->
        redirect(conn, to: return_to)
    end
  end

  def failure(conn, {strategy, phase}, reason) do
    Logger.warning(
      msg: "Sign-in failed",
      strategy: Atom.to_string(strategy),
      phase: Atom.to_string(phase),
      errors: Enum.join(failure_details(reason), ", ")
    )

    message =
      case reason do
        %AshAuthentication.Errors.AuthenticationFailed{
          caused_by: %Ash.Error.Forbidden{
            errors: [%AshAuthentication.Errors.CannotConfirmUnconfirmedUser{}]
          }
        } ->
          """
          You have already signed in another way, but have not confirmed your account.
          You can confirm your account using the link we sent to you, or by resetting your password.
          """

        _ ->
          "Sign-in failed"
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  defp failure_details(%AshAuthentication.Errors.AuthenticationFailed{caused_by: cause}) do
    [inspect(AshAuthentication.Errors.AuthenticationFailed) | failure_details(cause)]
  end

  defp failure_details(%Ash.Error.Changes.InvalidAttribute{private_vars: vars}) do
    constraint_details(Ash.Error.Changes.InvalidAttribute, (vars || [])[:constraint])
  end

  defp failure_details(%Ecto.ConstraintError{constraint: constraint}) do
    constraint_details(Ecto.ConstraintError, constraint)
  end

  defp failure_details(%Postgrex.Error{postgres: %{constraint: constraint}}) do
    constraint_details(Postgrex.Error, constraint)
  end

  defp failure_details(%module{errors: errors}) when is_list(errors) do
    [inspect(module) | Enum.flat_map(errors, &failure_details/1)]
  end

  defp failure_details(%module{}), do: [inspect(module)]
  defp failure_details(nil), do: ["no_reason"]
  defp failure_details(_reason), do: ["unclassified"]

  defp constraint_details(module, constraint) when is_binary(constraint),
    do: [inspect(module), "constraint=#{inspect(constraint)}"]

  defp constraint_details(module, _constraint), do: [inspect(module)]

  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/"

    conn
    |> clear_session(:tracker)
    |> redirect(to: return_to)
  end
end
