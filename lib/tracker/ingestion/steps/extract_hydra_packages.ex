defmodule Tracker.Ingestion.Steps.ExtractHydraPackages do
  @moduledoc """
  Stores the explicit package names selected by release-small.nix at each
  small-channel revision. Only the one release expression is read from the
  bare clone; listing attribute names does not force package derivations.

  Call `backfill/1` explicitly to populate already-ingested small-channel
  revisions, without repeating package ingestion.
  """

  @behaviour Tracker.Ingestion.Step

  alias Tracker.GitServer
  alias Tracker.GitServer.State
  alias Tracker.Ingestion.StepContext
  alias Tracker.Nixpkgs.{Channel, ChannelRevision}

  @release_file "nixos/release-small.nix"

  @impl Tracker.Ingestion.Step
  def timeout, do: :timer.minutes(2)

  @impl Tracker.Ingestion.Step
  def run(%StepContext{} = context) do
    run(context, GitServer.state())
  end

  def run(%StepContext{channel_revision: %ChannelRevision{} = revision}, %State{} = state) do
    revision.channel_id
    |> Channel.by_id!()
    |> then(&populate(revision, &1, state))
  end

  @doc """
  Backfills revisions in chronological channel order. Invoke explicitly from
  an IEx session with `Tracker.Ingestion.Steps.ExtractHydraPackages.backfill("nixos-unstable-small")`.
  An existing non-nil selection, including an empty list, is never recomputed.
  """
  def backfill(channel_name, state \\ GitServer.state()) when is_binary(channel_name) do
    channel = Channel.by_name!(channel_name)

    if small_channel?(channel.name) do
      channel.id
      |> ChannelRevision.by_channel_asc!()
      |> Enum.reduce_while(:ok, fn revision, :ok ->
        case populate(revision, channel, state) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      :ok
    end
  end

  def populate(%ChannelRevision{} = revision, %Channel{} = channel, %State{} = state) do
    if small_channel?(channel.name) and is_nil(revision.hydra_package_attributes) do
      with {:ok, names} <- extract_names(revision.revision, state),
           {:ok, _} <-
             ChannelRevision.record_hydra_package_attributes(revision, %{
               hydra_package_attributes: names
             }) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @doc "Extracts only top-level selected nixpkgs attribute names at an exact commit."
  def extract_names(sha, %State{} = state) do
    with {:ok, source} <- GitServer.show_file(sha, @release_file, state),
         {:ok, names} <- evaluate_names(source) do
      {:ok, names}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp small_channel?(name),
    do: String.starts_with?(name, "nixos-") and String.ends_with?(name, "-small")

  defp evaluate_names(source) do
    directory =
      Path.join(System.tmp_dir!(), "tracker-release-small-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir(directory) do
      try do
        file = Path.join(directory, "release-small.nix")

        with :ok <- File.write(file, source) do
          expression =
            "builtins.attrNames ((import (builtins.toPath #{inspect(file)}) {}).nixpkgs)"

          case System.cmd(
                 "nix-instantiate",
                 ["--eval", "--strict", "--json", "--expr", expression],
                 stderr_to_stdout: true
               ) do
            {json, 0} -> decode_names(json)
            {message, status} -> {:error, {:nix_eval_failed, status, String.trim(message)}}
          end
        else
          {:error, reason} -> {:error, reason}
        end
      after
        File.rm_rf!(directory)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_names(json) do
    case Jason.decode(json) do
      {:ok, names} when is_list(names) ->
        if Enum.all?(names, &is_binary/1), do: {:ok, names}, else: {:error, :invalid_selection}

      {:ok, _} ->
        {:error, :invalid_selection}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
