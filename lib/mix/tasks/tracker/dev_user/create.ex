defmodule Mix.Tasks.Tracker.DevUser.Create do
  @shortdoc "Creates a development user and mints a local sign-in token"
  @moduledoc """
  Creates (or refreshes) a development user and writes a sign-in token to a
  gitignored local file, printing the URL that signs a browser in as them.

  The user is also subscribed to a handful of already-ingested packages, a
  channel and a change, and given back-dated notifications drawn from what
  actually happened in the most recent revisions, so the inbox has something
  real to render. Both are idempotent: re-running rotates the token and leaves
  the seeded rows alone.

  The route that consumes the token only exists when `:dev_routes` is enabled,
  so this is not a way into a production deployment.

  ## Usage

      mix tracker.dev_user.create [--username devuser] [--admin] [--notifications 12]

  ## Options

    * `--username`      - GitHub username to register the dev user under (default `devuser`)
    * `--admin`         - also grant the `:admin` role, which unlocks `/dev` and `/admin`
    * `--notifications` - how many notifications to seed (default 12, `0` to seed nothing)
  """

  use Mix.Task

  alias Tracker.Accounts.User
  alias Tracker.Nixpkgs.{Change, Channel, ChannelRevision, Package}

  alias Tracker.Notifications.{
    ChangeSubscription,
    ChannelSubscription,
    Notification,
    PackageSubscription
  }

  @switches [username: :string, admin: :boolean, notifications: :integer]
  @default_username "devuser"
  @default_notifications 12
  @packages_per_event_type 2
  @subscribed_packages 5

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    opts = parse!(args)

    user =
      opts[:username]
      |> register()
      |> maybe_grant_admin(opts[:admin])

    seed(user, opts[:notifications])

    token = Tracker.DevLogin.issue!(user.github_username)

    Mix.shell().info("""
    Dev user #{user.github_username} (roles: #{Enum.join(user.roles, ", ")})
    Token written to #{Tracker.DevLogin.path()}
    Sign in at #{TrackerWeb.Endpoint.url()}/dev/login/#{token}
    """)
  end

  @doc false
  def parse!(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    opts
    |> Keyword.put_new(:username, @default_username)
    |> Keyword.put_new(:notifications, @default_notifications)
  end

  defp register(username) do
    User
    |> Ash.Changeset.for_create(:register_with_github,
      user_info: %{"id" => github_id(username), "login" => username},
      oauth_tokens: %{"access_token" => "dev"}
    )
    |> Ash.create!(authorize?: false)
  end

  defp maybe_grant_admin(user, true), do: User.grant_admin!(user, authorize?: false)
  defp maybe_grant_admin(user, _), do: user

  # Negative so a dev user can never collide with, or masquerade as, a real
  # GitHub account; stable so re-runs upsert the same user.
  defp github_id(username), do: -:erlang.phash2(username)

  defp seed(_user, 0), do: :ok

  defp seed(user, count) do
    case Enum.find(Channel.active!(), &(latest_revisions(&1, 1) != [])) do
      nil ->
        Mix.shell().info("No ingested channel data yet — seeded nothing to look at.")

      channel ->
        changes = Change.list!(nil, nil, channel.name, page: [limit: 3]).results
        rows = user |> rows(channel, changes, count) |> Enum.take(count)

        subscribe(user, channel, rows, changes)
        :ok = Notification.fanout(rows)
        mark_oldest_read(user)
    end
  end

  # One burst per revision, newest first and timed to its release: the
  # publication itself, the packages that actually changed in it, and — on the
  # newest — the changes that reached the channel. The shape the fan-out
  # workers produce.
  defp rows(user, channel, changes, count) do
    channel
    |> latest_revisions(revision_depth(count))
    |> Enum.with_index()
    |> Enum.flat_map(fn {revision, index} ->
      ([%{type: :channel_revision_published, channel_id: channel.id}] ++
         package_rows(revision, channel) ++ change_rows(changes, channel, index))
      |> Enum.map(&stamp(&1, user, revision))
    end)
  end

  # Each revision contributes a handful of rows; only diff back far enough to
  # fill the requested count.
  defp revision_depth(count), do: count |> Kernel.+(4) |> div(5) |> min(8)

  defp latest_revisions(channel, limit) do
    ChannelRevision.by_channel!(channel.id, query: [sort: [released_at: :desc], limit: limit])
  end

  defp package_rows(%{previous_channel_revision_id: nil}, _channel), do: []

  defp package_rows(revision, channel) do
    previous = ChannelRevision.get_by_id!(revision.previous_channel_revision_id)

    sample =
      previous
      |> ChannelRevision.version_diff(revision)
      |> Enum.group_by(&event_type/1)
      |> Enum.flat_map(fn {_type, diffs} -> Enum.take(diffs, @packages_per_event_type) end)

    ids =
      sample
      |> Enum.map(& &1.attribute)
      |> Package.ids_by_attributes!()
      |> Map.new(&{&1.attribute, &1.id})

    for diff <- sample, id = ids[diff.attribute] do
      %{type: event_type(diff), package_id: id, channel_id: channel.id}
    end
  end

  defp event_type(%{old_version: nil}), do: :package_added
  defp event_type(%{new_version: nil}), do: :package_removed
  defp event_type(_diff), do: :package_version_changed

  defp change_rows(changes, channel, 0) do
    for change <- changes,
        do: %{type: :change_propagated, change_id: change.id, channel_id: channel.id}
  end

  defp change_rows(_changes, _channel, _index), do: []

  defp stamp(row, user, revision) do
    Map.merge(row, %{
      user_id: user.id,
      channel_revision_id: revision.id,
      occurred_at: revision.released_at,
      dedup_key:
        Enum.join(
          ["dev", user.github_username, revision.id, row.type, row[:package_id], row[:change_id]],
          ":"
        )
    })
  end

  defp subscribe(user, channel, rows, changes) do
    ChannelSubscription.subscribe!(channel.id, actor: user)

    for package_id <- subscribable_packages(rows) do
      PackageSubscription.subscribe!(package_id, nil, actor: user)
    end

    for change <- Enum.take(changes, 1),
        do: ChangeSubscription.subscribe!(change.id, nil, actor: user)

    :ok
  end

  defp subscribable_packages(rows) do
    rows
    |> Enum.map(& &1[:package_id])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@subscribed_packages)
  end

  defp mark_oldest_read(user) do
    notifications = Notification.for_user!(actor: user)

    notifications
    |> Enum.take(-div(length(notifications), 3))
    |> Enum.each(&Notification.mark_read!(&1, actor: user))
  end
end
