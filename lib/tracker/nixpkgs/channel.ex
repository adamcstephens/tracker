defmodule Tracker.Nixpkgs.Channel do
  @moduledoc """
  Utility functions for fetching nixpkgs channel data from S3.
  """

  @doc """
  Resolves the latest revision and base URL for a channel.

  Follows the redirect from channels.nixos.org to get the stable
  base URL, then fetches the git revision from that release.
  """
  def get_channel_revision(channel) do
    [base_url] =
      Req.get!(Tracker.Nixpkgs.S3Cache.new(),
        url: "https://channels.nixos.org/#{channel}",
        redirect: false,
        cache: false
      ).headers["location"]

    revision = Req.get!(Tracker.Nixpkgs.S3Cache.new(), url: base_url <> "/git-revision").body

    {revision, base_url}
  end

  @doc """
  Fetches the raw brotli-compressed packages.json.br binary for a channel release.

  Returns the compressed binary, suitable for streaming via `PackageStream`.
  """
  def fetch_packages_compressed(base_url) do
    Req.get!(Tracker.Nixpkgs.S3Cache.new(), url: base_url <> "/packages.json.br", raw: true).body
  end

  @doc """
  Fetches and decompresses options.json.br for a channel release.

  Returns a map of option name to option data.
  """
  def fetch_options(base_url) do
    Req.get!(Tracker.Nixpkgs.S3Cache.new(), url: base_url <> "/options.json.br", raw: true).body
    |> ExBrotli.decompress!()
    |> :json.decode()
  end

  @doc """
  Computes the longest common dot-separated prefix for a list of option names.

  For a single option name, returns all but the last segment
  (or the name itself if single-segment).
  """
  def display_name_for_options([single]) do
    case String.split(single, ".") do
      [one] -> one
      parts -> parts |> Enum.drop(-1) |> Enum.join(".")
    end
  end

  def display_name_for_options(option_names) do
    split_names = Enum.map(option_names, &String.split(&1, "."))

    split_names
    |> Enum.zip_reduce([], fn segments, acc ->
      segment = hd(segments)

      if Enum.all?(segments, &(&1 == segment)) do
        [segment | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
    |> case do
      [] -> hd(option_names)
      parts -> Enum.join(parts, ".")
    end
  end
end
