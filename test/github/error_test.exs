defmodule GitHub.ErrorTest do
  use ExUnit.Case, async: true

  alias GitHub.Error

  test "new/1 builds a struct with the given fields" do
    error = Error.new(code: 500, message: "boom", reason: :server_error, step: {Foo, :bar})

    assert %Error{code: 500, message: "boom", reason: :server_error, step: {Foo, :bar}} = error
  end

  test "new/1 defaults reason to :error and message to a placeholder" do
    error = Error.new(code: 418)

    assert error.reason == :error
    assert is_binary(error.message)
  end

  test "matches the rate-limited shape workers rely on" do
    assert %Error{reason: :rate_limited} = Error.new(reason: :rate_limited, code: 403)
  end
end
