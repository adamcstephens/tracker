defmodule Tracker.Ingestion.PackageStream do
  @moduledoc """
  Rustler NIF for streaming packages.json.br ingestion.

  Brotli-decompresses and SAX-parses a compressed packages.json binary,
  sending packages in batches to the given pid via enif_send.

  This is a synchronous `DirtyCpu` NIF: it runs on a runtime-managed dirty
  scheduler and blocks its caller until parsing completes, returning `:ok`.
  Run it from a process *other* than the receiver (e.g. `Task.async/1`) — if
  the caller is also the receiver, the batches pile in its own mailbox while
  it is blocked and never get drained.

  ## Message protocol

    * `{:packages, [{attribute, fields_map}, ...]}` — batch of packages (up to 500)
    * `{:done, %{version: integer}}` — stream complete
    * `{:error, reason}` — failure during decompression or parsing
  """

  use Rustler,
    otp_app: :tracker,
    crate: "package_stream"

  @spec stream_packages(binary(), pid()) :: :ok
  def stream_packages(_compressed_data, _caller_pid), do: :erlang.nif_error(:nif_not_loaded)
end
