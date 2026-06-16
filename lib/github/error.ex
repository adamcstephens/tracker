defmodule GitHub.Error do
  @moduledoc """
  Error returned by the `GitHub` API client.

  Callers match on `reason` and `code` to react to specific failures. The
  reasons used by this client are:

    * `:rate_limited` — a primary or secondary rate limit was hit
    * `:server_error` — GitHub returned a 5xx response
    * `:error` — any other transport or client failure (the default)
  """

  use TypedStruct

  typedstruct do
    field :code, integer()
    field :message, String.t(), default: "Unknown Error"
    field :reason, atom(), default: :error
    field :source, term()
    field :step, {module(), atom()}
  end

  @doc """
  Builds an error struct from the given fields.
  """
  @spec new(keyword) :: t()
  def new(fields) when is_list(fields) do
    struct(__MODULE__, fields)
  end
end
