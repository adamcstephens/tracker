defmodule Tracker.Ingestion.PackageStream do
  @moduledoc """
  Rustler NIF for streaming packages.json.br ingestion.

  Brotli-decompresses and SAX-parses a compressed packages.json binary,
  sending each package as a message to the caller process via enif_send.

  ## Message protocol

    * `{:package, attribute, fields_map}` — one per package
    * `{:done, %{version: integer}}` — stream complete
    * `{:error, reason}` — failure during decompression or parsing
  """

  use Rustler,
    otp_app: :tracker,
    crate: "package_stream"

  @spec stream_packages(binary(), pid()) :: :ok
  def stream_packages(_compressed_data, _caller_pid), do: :erlang.nif_error(:nif_not_loaded)
end
