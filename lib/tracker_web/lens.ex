defmodule TrackerWeb.Lens do
  @moduledoc """
  Sitewide channel lens — a persistent filter for channel (and optional revision)
  that applies across all pages.

  The lens lives in the URL: `lens_channel` and `lens_rev` query params are its
  canonical source. The `_tracker_lens` cookie is a preference only, seeding the
  lens on a request that carries no params (see `TrackerWeb.Plug.Lens`).
  """

  use TypedStruct

  alias Tracker.Nixpkgs.Channel
  alias Tracker.Nixpkgs.ChannelRevision

  @cookie_max_age 365 * 24 * 60 * 60
  @cookie_salt "tracker_lens"

  typedstruct do
    field :channel, Channel.t(), enforce: true
    field :revision, ChannelRevision.t() | nil
    field :disabled?, boolean(), default: false
    field :all?, boolean(), default: false
  end

  @doc """
  Resolves a lens from a channel name and optional revision hash.

  Falls back to the default stable channel when the given name is nil, empty,
  or not found.
  """
  @spec resolve(String.t() | nil, String.t() | nil) :: t() | nil
  def resolve("all", _rev_hash) do
    case default_channel() do
      nil -> nil
      channel -> %__MODULE__{channel: channel, all?: true}
    end
  end

  def resolve(channel_name, rev_hash) do
    case resolve_channel(channel_name) do
      nil ->
        nil

      channel ->
        revision =
          case rev_hash do
            nil -> nil
            "" -> nil
            hash -> resolve_revision(channel, hash)
          end

        %__MODULE__{channel: channel, revision: revision}
    end
  end

  @doc """
  Resolves the lens for a request, preferring URL params over the session
  seeded from the cookie.
  """
  @spec from_params(map(), map()) :: t() | nil
  def from_params(params, session \\ %{})

  def from_params(%{"lens_channel" => channel_name} = params, _session) do
    resolve(channel_name, params["lens_rev"])
  end

  def from_params(_params, session) do
    resolve(session["lens_channel_name"], session["lens_rev"])
  end

  @doc """
  Rewrites a path so it carries the given lens, leaving its other query params
  untouched. A channel switch clears any pinned revision.
  """
  @spec path_for(String.t(), String.t(), String.t() | nil) :: String.t()
  def path_for(path, channel_name, rev \\ nil) do
    uri = URI.parse(path)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.drop(["lens_rev"])
      |> Map.put("lens_channel", channel_name)
      |> then(fn params -> if rev, do: Map.put(params, "lens_rev", rev), else: params end)
      |> URI.encode_query()

    URI.to_string(%{uri | query: query})
  end

  @doc """
  LiveView hook resolving the lens from the URL on every navigation.
  """
  def on_mount(:default, _params, session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(socket, :lens, :handle_params, fn params, uri, socket ->
       {:cont,
        socket
        |> Phoenix.Component.assign(:lens, from_params(params, session))
        |> Phoenix.Component.assign(:current_path, request_path(uri))}
     end)}
  end

  defp request_path(uri) do
    %URI{path: path, query: query} = URI.parse(uri)

    URI.to_string(%URI{path: path, query: query})
  end

  @doc """
  Serializes a lens to a cookie-safe string.

  Format: `"channel_name"` or `"channel_name:revision_hash"`.
  """
  @spec cookie_value(t()) :: String.t()
  def cookie_value(%__MODULE__{all?: true}) do
    "all"
  end

  def cookie_value(%__MODULE__{channel: channel, revision: nil}) do
    channel.name
  end

  def cookie_value(%__MODULE__{channel: channel, revision: revision}) do
    "#{channel.name}:#{revision.revision}"
  end

  @doc """
  Parses a cookie value string back to a `{channel_name, revision_hash}` tuple.
  """
  @spec from_cookie(String.t() | nil) :: {String.t() | nil, String.t() | nil}
  def from_cookie(nil), do: {nil, nil}
  def from_cookie(""), do: {nil, nil}

  def from_cookie(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [name, rev] -> {name, rev}
      [name] -> {name, nil}
    end
  end

  @doc """
  Signs a lens value for storage in a cookie.
  """
  @spec sign_cookie(t()) :: String.t()
  def sign_cookie(%__MODULE__{} = lens) do
    Phoenix.Token.sign(TrackerWeb.Endpoint, @cookie_salt, cookie_value(lens))
  end

  @doc """
  Verifies a signed cookie token and returns the raw value.
  """
  @spec verify_cookie(String.t()) :: {:ok, String.t()} | :error
  def verify_cookie(token) when is_binary(token) do
    case Phoenix.Token.verify(TrackerWeb.Endpoint, @cookie_salt, token, max_age: @cookie_max_age) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> :error
    end
  end

  @doc """
  Returns the channel ID for filtering, or nil when the lens is nil or set to "all".
  """
  @spec channel_id(t() | nil) :: Ash.UUID.t() | nil
  def channel_id(nil), do: nil
  def channel_id(%__MODULE__{all?: true}), do: nil
  def channel_id(%__MODULE__{channel: channel}), do: channel.id

  @doc """
  Returns the channel name for filtering, or nil when the lens is nil or set to "all".
  """
  @spec channel_name(t() | nil) :: String.t() | nil
  def channel_name(nil), do: nil
  def channel_name(%__MODULE__{all?: true}), do: nil
  def channel_name(%__MODULE__{channel: channel}), do: channel.name

  @doc """
  The `released_at` of the pinned revision, or nil when the lens carries no pin.
  Metadata reads resolve at this instant; historical lists stay channel-scoped.
  """
  @spec pinned_at(t() | nil) :: DateTime.t() | nil
  def pinned_at(%__MODULE__{revision: %ChannelRevision{released_at: released_at}}),
    do: released_at

  def pinned_at(_lens), do: nil

  @doc """
  The maximum age for the lens cookie, in seconds.
  """
  def cookie_max_age, do: @cookie_max_age

  @doc """
  The salt used for signing cookies.
  """
  def cookie_salt, do: @cookie_salt

  defp resolve_channel(nil), do: default_channel()
  defp resolve_channel(""), do: default_channel()

  defp resolve_channel(name) do
    case Channel.by_name(name) do
      {:ok, channel} -> channel
      {:error, _} -> default_channel()
    end
  end

  defp default_channel do
    case Channel.default_stable() do
      {:ok, channel} -> channel
      {:error, _} -> Channel.read!() |> List.first()
    end
  end

  defp resolve_revision(channel, hash) do
    case ChannelRevision.find_by_channel_hash(channel.id, hash) do
      {:ok, revision} -> revision
      {:error, _} -> nil
    end
  end
end
