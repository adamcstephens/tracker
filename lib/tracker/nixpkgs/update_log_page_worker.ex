defmodule Tracker.Nixpkgs.UpdateLogPageWorker do
  @moduledoc """
  Reconciles package update-log directory links from the root index every four hours.
  Individual directories are never fetched.
  """
  use Oban.Worker, queue: :ingestion, max_attempts: 1, unique: [period: 60]

  require Logger

  alias Tracker.Nixpkgs.UpdateLogPage

  @index_url "https://nixpkgs-update-logs.nix-community.org/"

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case run() do
      {:ok, _counts} ->
        :ok

      {:error, reason} = error ->
        Logger.warning(msg: "update log index fetch failed", reason: inspect(reason))
        error
    end
  end

  @doc "Runs one fetch and reconciliation cycle. Pass `:fetch` to supply an index fetcher."
  def run(opts \\ []) do
    fetch = Keyword.get(opts, :fetch, &fetch_index/0)

    with {:ok, html} <- fetch.(),
         {:ok, pages} <- parse_index(html) do
      existing = UpdateLogPage.read!()
      existing_by_attribute = Map.new(existing, &{&1.attribute, &1})

      updated =
        Enum.count(pages, fn {attribute, url} ->
          case Map.get(existing_by_attribute, attribute) do
            %UpdateLogPage{url: ^url} ->
              false

            _ ->
              UpdateLogPage.upsert!(attribute, url)
              true
          end
        end)

      removed =
        Enum.count(existing, fn %UpdateLogPage{} = page ->
          if Map.has_key?(pages, page.attribute) do
            false
          else
            UpdateLogPage.destroy!(page)
            true
          end
        end)

      {:ok, %{updated: updated, removed: removed}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Parses only direct child directory anchors from a valid root directory index."
  def parse_index(html) when is_binary(html) do
    with {:ok, document} <- Floki.parse_document(html),
         true <-
           document
           |> Floki.find("h1")
           |> Enum.any?(&(Floki.text(&1) |> String.trim() == "Index of /")) do
      pages =
        document
        |> Floki.find("a[href]")
        |> Enum.reduce(%{}, fn anchor, pages ->
          case anchor |> Floki.attribute("href") |> List.first() |> directory_attribute() do
            {:ok, attribute, href} ->
              Map.put_new(pages, attribute, URI.merge(@index_url, href) |> to_string())

            :skip ->
              pages
          end
        end)

      if map_size(pages) > 0, do: {:ok, pages}, else: {:error, :empty_index}
    else
      false -> {:error, :invalid_index}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse_index(_), do: {:error, :invalid_index}

  defp directory_attribute(nil), do: :skip

  defp directory_attribute(href) do
    case String.split(href, "/") do
      [encoded, ""] when byte_size(encoded) > 0 ->
        if String.match?(encoded, ~r/%(?![0-9a-fA-F]{2})/) do
          :skip
        else
          attribute = URI.decode(encoded)

          if attribute not in [".", ".."] and String.valid?(attribute) and
               not String.match?(attribute, ~r/[\x00-\x1f\x7f\\\/?#]/) do
            {:ok, attribute, href}
          else
            :skip
          end
        end

      _ ->
        :skip
    end
  end

  defp fetch_index do
    case Req.get(@index_url, retry: false, decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
