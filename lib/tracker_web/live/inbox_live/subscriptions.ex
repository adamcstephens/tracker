defmodule TrackerWeb.InboxLive.Subscriptions do
  @moduledoc """
  The user's subscriptions, grouped by kind (packages, channels,
  changes). Each row links to the subscribed item and shows its channel
  scope and when the subscription was created.
  """
  use TrackerWeb, :live_view

  import TrackerWeb.InboxLive.Index, only: [view_nav: 1]

  on_mount {TrackerWeb.LiveUserAuth, :live_user_required}

  alias Tracker.Notifications.ChangeSubscription
  alias Tracker.Notifications.ChannelSubscription
  alias Tracker.Notifications.PackageSubscription
  alias TrackerWeb.NotificationPresenter
  alias TrackerWeb.PageSearch

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Subscriptions")
     |> assign(
       :package_subs,
       PackageSubscription.for_user!(actor: user, load: [:package, :channel])
     )
     |> assign(:channel_subs, ChannelSubscription.for_user!(actor: user, load: [:channel]))
     |> assign(:change_subs, ChangeSubscription.for_user!(actor: user, load: [:change, :channel]))
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = params["search"] || ""
    lens = socket.assigns.lens && %{socket.assigns.lens | disabled?: true}

    {:noreply,
     socket
     |> assign(:lens, lens)
     |> assign(:search, search)
     |> assign(:page_search, %PageSearch{
       action: "/inbox/subscriptions",
       value: search,
       placeholder: "Search subscriptions…"
     })
     |> apply_search()}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     socket
     |> assign(:search, search)
     |> update(:page_search, &%{&1 | value: search})
     |> apply_search()
     |> push_event("update-url", %{path: subscriptions_path(search)})}
  end

  defp apply_search(socket) do
    %{package_subs: packages, channel_subs: channels, change_subs: changes, search: search} =
      socket.assigns

    query = search |> String.trim() |> String.downcase()

    visible_packages =
      Enum.filter(packages, &search_match?(query, [&1.package.attribute, scope_name(&1)]))

    visible_channels = Enum.filter(channels, &search_match?(query, [&1.channel.name]))

    visible_changes =
      Enum.filter(
        changes,
        &search_match?(query, ["##{&1.change.number}", &1.change.title, scope_name(&1)])
      )

    socket
    |> assign(:visible_package_subs, visible_packages)
    |> assign(:visible_channel_subs, visible_channels)
    |> assign(:visible_change_subs, visible_changes)
    |> assign(:any_subs?, packages != [] or channels != [] or changes != [])
    |> assign(
      :any_visible?,
      visible_packages != [] or visible_channels != [] or visible_changes != []
    )
  end

  defp scope_name(sub), do: sub.channel && sub.channel.name

  defp search_match?("", _texts), do: true

  defp search_match?(query, texts) do
    Enum.any?(texts, fn text ->
      is_binary(text) and String.contains?(String.downcase(text), query)
    end)
  end

  defp subscriptions_path(search) do
    case String.trim(search) do
      "" -> ~p"/inbox/subscriptions"
      search -> ~p"/inbox/subscriptions?search=#{search}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ibx">
      <div class="ibx-toolbar">
        <.view_nav active={:subscriptions} />
      </div>

      <p :if={!@any_subs?} id="subscriptions-empty" class="ibx-empty">
        No subscriptions yet. Subscribe from a package, channel, or change page.
      </p>

      <div :if={@any_subs? && !@any_visible?} class="ibx-empty">
        Nothing matches this search.
      </div>

      <.section
        :if={@visible_package_subs != []}
        title="Packages"
        count={length(@visible_package_subs)}
      >
        <.sub_row
          :for={sub <- @visible_package_subs}
          id={"package-subscription-#{sub.id}"}
          kind="package"
          path={~p"/packages/#{sub.package.attribute}"}
          label={sub.package.attribute}
          scope={(sub.channel && sub.channel.name) || "All channels"}
          at={sub.inserted_at}
          now={@now}
        />
      </.section>

      <.section
        :if={@visible_channel_subs != []}
        title="Channels"
        count={length(@visible_channel_subs)}
      >
        <.sub_row
          :for={sub <- @visible_channel_subs}
          id={"channel-subscription-#{sub.id}"}
          kind="channel"
          path={~p"/channels/#{sub.channel.name}"}
          label={sub.channel.name}
          at={sub.inserted_at}
          now={@now}
        />
      </.section>

      <.section
        :if={@visible_change_subs != []}
        title="Changes"
        count={length(@visible_change_subs)}
      >
        <.sub_row
          :for={sub <- @visible_change_subs}
          id={"change-subscription-#{sub.id}"}
          kind="change"
          path={~p"/changes/#{sub.change.number}"}
          label={"##{sub.change.number} #{sub.change.title}"}
          scope={(sub.channel && sub.channel.name) || "Any branch"}
          at={sub.inserted_at}
          now={@now}
        />
      </.section>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :count, :integer, required: true
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <section class="ibx-day">
      <div class="ibx-day-head">
        <h2>{@title}</h2>
        <span class="rule"></span>
        <span class="n">{@count}</span>
      </div>
      <ul class="ibx-list">
        {render_slot(@inner_block)}
      </ul>
    </section>
    """
  end

  @type_colors %{"package" => "update", "channel" => "revision", "change" => "propagate"}

  attr :id, :string, required: true
  attr :kind, :string, required: true, values: ~w(package channel change)
  attr :path, :string, required: true
  attr :label, :string, required: true
  attr :scope, :string, default: nil
  attr :at, :any, required: true
  attr :now, :any, required: true

  defp sub_row(assigns) do
    assigns = assign(assigns, :type_color, Map.fetch!(@type_colors, assigns.kind))

    ~H"""
    <li id={@id} class="ibx-row" style={"--type-color: var(--t-#{@type_color})"}>
      <span class="ibx-glyph"><.icon name={@kind} /></span>
      <div class="ibx-body">
        <div class="ibx-line1">
          <span class="ibx-attr"><.link navigate={@path}>{@label}</.link></span>
        </div>
        <div class="ibx-line2">
          <span :if={@scope} class="ibx-tag"><span class="dot"></span>{@scope}</span>
          <span :if={@scope} class="ibx-dot-sep">·</span>
          <time class="ibx-time" title={NotificationPresenter.clock_utc(@at)}>
            subscribed {NotificationPresenter.relative_time(@at, @now)}
          </time>
        </div>
      </div>
    </li>
    """
  end

  attr :name, :string, required: true

  defp icon(assigns) do
    ~H"""
    <svg
      class="ibx-icon"
      aria-hidden="true"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <%= case @name do %>
        <% "package" -> %>
          <path d="M21 8 12 3 3 8v8l9 5 9-5V8Z" /><path d="m3 8 9 5 9-5" /><path d="M12 13v8" />
        <% "channel" -> %>
          <path d="M3 12h4l3 7 4-14 3 7h4" />
        <% "change" -> %>
          <circle cx="6" cy="6" r="2.5" /><circle cx="6" cy="18" r="2.5" /><circle
            cx="18"
            cy="18"
            r="2.5"
          /><path d="M6 8.5v3a4 4 0 0 0 4 4h5.5" />
      <% end %>
    </svg>
    """
  end
end
