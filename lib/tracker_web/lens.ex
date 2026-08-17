defmodule TrackerWeb.Lens do
  @moduledoc """
  Sitewide channel lens — a persistent filter for channel (and optional revision)
  that applies across all pages.

  The lens lives in the URL: the `channel` and `rev` query params are the only
  thing that decides what a page renders. Everything else here exists so those
  params are always present and always truthful.

    * `on_mount/4` resolves the lens from the params, and when they disagree with
      the lens that actually rendered it patches the URL to match.
    * `decorate/1` puts the lens on every internal link, so a navigation states
      the channel it is heading to rather than inheriting one.
    * The `_tracker_lens` cookie is a preference only, seeding the lens on an
      entry that carries no params. It reaches a dead request through
      `TrackerWeb.Plug.Lens` and a live one through the `_lens` connect param,
      which the client re-reads on every join.
  """

  use TypedStruct

  alias Tracker.Nixpkgs.Channel
  alias Tracker.Nixpkgs.ChannelRevision

  @cookie_max_age 365 * 24 * 60 * 60
  @cookie_salt "tracker_lens"
  @ambient_key :tracker_lens

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
  Resolves the lens a set of URL params states, or nil when they state none.
  """
  @spec from_params(map()) :: t() | nil
  def from_params(%{"channel" => channel_name} = params) do
    resolve(channel_name, params["rev"])
  end

  def from_params(_params), do: nil

  @doc """
  The `{channel_name, revision_hash}` a lens serializes to in the URL.
  """
  @spec canonical(t() | nil) :: {String.t() | nil, String.t() | nil}
  def canonical(nil), do: {nil, nil}
  def canonical(%__MODULE__{all?: true}), do: {"all", nil}
  def canonical(%__MODULE__{channel: channel, revision: nil}), do: {channel.name, nil}

  def canonical(%__MODULE__{channel: channel, revision: revision}),
    do: {channel.name, revision.revision}

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
      |> Map.drop(["rev"])
      |> Map.put("channel", channel_name)
      |> then(fn params -> if rev, do: Map.put(params, "rev", rev), else: params end)
      |> URI.encode_query()

    URI.to_string(%{uri | query: query})
  end

  @doc """
  Stores the lens for the current process, where `decorate/1` can reach it.

  Function components cannot see socket assigns, and every internal link is one,
  so the lens in force travels as ambient state for the duration of a render.
  Set once per `handle_params` by `on_mount/4`, in the LiveView process when
  connected and in the request process for the dead render.
  """
  @spec put_current(t() | nil) :: t() | nil
  def put_current(lens) do
    Process.put(@ambient_key, lens)
    lens
  end

  @doc """
  The lens in force for the current render, if any.
  """
  @spec current() :: t() | nil
  def current, do: Process.get(@ambient_key)

  @doc """
  Puts the lens in force on a local path, so following the link states the
  channel rather than inheriting whatever the next page resolves.

  Leaves alone anything that is not ours to rewrite: external and
  scheme-relative targets, fragments, static assets, and a path that already
  states its own channel.
  """
  @spec decorate(term()) :: term()
  def decorate(path) when is_binary(path) do
    case current() do
      nil -> path
      lens -> if decorate?(path), do: apply_lens(path, lens), else: path
    end
  end

  def decorate(path), do: path

  @doc """
  LiveView hook resolving the lens from the URL on every navigation.
  """
  def on_mount(:default, _params, session, socket) do
    socket = Phoenix.Component.assign(socket, :lens_preference, preference(socket, session))

    {:cont, Phoenix.LiveView.attach_hook(socket, :lens, :handle_params, &resolve_params/3)}
  end

  # The lens the URL states, falling back to the preference on an entry that
  # states none. A preference can only seed a lens, never override the URL.
  defp resolve_params(params, uri, socket) do
    {channel_name, rev} = stated(params, socket.assigns.lens_preference)
    lens = put_current(resolve(channel_name, rev))

    socket =
      socket
      |> Phoenix.Component.assign(:lens, lens)
      |> Phoenix.Component.assign(:current_path, request_path(uri))

    {:cont, canonicalize(socket, params, lens)}
  end

  defp stated(%{"channel" => channel_name} = params, _preference),
    do: {channel_name, params["rev"]}

  defp stated(_params, preference), do: preference

  # A page that rendered a different lens than its URL states is unshareable and
  # unreadable, so the URL is rewritten to what rendered. Nothing to do on the
  # dead render: the connected mount that follows it canonicalizes.
  defp canonicalize(socket, params, lens) do
    canonical = canonical(lens)

    if lens && Phoenix.LiveView.connected?(socket) &&
         canonical != {params["channel"], presence(params["rev"])} do
      {channel_name, rev} = canonical

      Phoenix.LiveView.push_patch(socket,
        to: path_for(socket.assigns.current_path, channel_name, rev),
        replace: true
      )
    else
      socket
    end
  end

  # The cookie, fresh: read server-side on a dead request by
  # `TrackerWeb.Plug.Lens`, and handed back by the client on every live join,
  # which is the only way a LiveView sees a cookie written mid-session.
  defp preference(socket, session) do
    case Phoenix.LiveView.get_connect_params(socket) do
      %{"_lens" => token} when is_binary(token) ->
        case verify_cookie(token) do
          {:ok, value} -> from_cookie(value)
          :error -> {nil, nil}
        end

      _ ->
        {session["lens_channel_name"], session["lens_rev"]}
    end
  end

  defp apply_lens(path, lens) do
    {channel_name, rev} = canonical(lens)

    path_for(path, channel_name, rev)
  end

  defp decorate?("//" <> _rest), do: false
  defp decorate?("/" <> rest = path), do: not asset?(rest) and not states_channel?(path)
  defp decorate?(_path), do: false

  defp asset?(rest) do
    [first | _] = String.split(rest, ["/", "?", "#"], parts: 2)

    first in TrackerWeb.static_paths()
  end

  defp states_channel?(path) do
    %URI{query: query} = URI.parse(path)

    is_binary(query) and Map.has_key?(URI.decode_query(query), "channel")
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

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
      {:error, _} -> Channel.newest_nixos!()
    end
  end

  defp resolve_revision(channel, hash) do
    case ChannelRevision.find_by_channel_hash(channel.id, hash) do
      {:ok, revision} -> revision
      {:error, _} -> nil
    end
  end
end
