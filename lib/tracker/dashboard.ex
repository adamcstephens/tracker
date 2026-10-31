defmodule Tracker.Dashboard do
  use TypedStruct

  alias Tracker.Accounts.User
  alias Tracker.Nixpkgs.{Channel, ChannelRevision, Change, RevisionComparison}
  alias Tracker.Notifications.{ChangeSubscription, Notification}
  alias TrackerWeb.Lens

  @channel_names ["nixos-unstable", "nixos-26.05", "nixos-unstable-small"]

  defmodule ChannelSummary do
    use TypedStruct

    typedstruct do
      field :channel, Channel.t(), enforce: true
      field :revision, ChannelRevision.t() | nil
      field :previous_revision, ChannelRevision.t() | nil
      field :status, atom(), default: :no_release
      field :package_status, atom(), default: :no_release
      field :option_status, atom(), default: :no_release
      field :package_counts, RevisionComparison.Counts.t() | nil
      field :option_counts, RevisionComparison.Counts.t() | nil
      field :package_rows, [RevisionComparison.PackageRow.t()], default: []
      field :option_rows, [RevisionComparison.OptionRow.t()], default: []
    end
  end

  defmodule FollowedChange do
    use TypedStruct

    typedstruct do
      field :change, Change.t(), enforce: true
      field :subscription, ChangeSubscription.t(), enforce: true
      field :landed_in, String.t() | nil
    end
  end

  typedstruct do
    field :all?, boolean(), default: false
    field :selected, ChannelSummary.t() | nil
    field :channels, [ChannelSummary.t()], default: []
    field :notifications, [Notification.t()], default: []
    field :unread_count, non_neg_integer(), default: 0
    field :followed, [FollowedChange.t()], default: []
    field :followed_count, non_neg_integer(), default: 0
    field :recent_changes, [Change.t()], default: []
  end

  def load(lens, user) do
    channels =
      Channel.read!(
        query: [filter: [name: [in: @channel_names]]],
        load: [:build_problem?, :latest_release]
      )

    revisions = Map.new(channels, &{&1.id, ChannelRevision.latest_at!(&1.id)})
    selected_revision = selected_revision(lens, revisions)

    previous_ids =
      [selected_revision | Map.values(revisions)]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.previous_channel_revision_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    previous = Map.new(ChannelRevision.by_ids!(previous_ids), &{&1.id, &1})

    selected =
      case lens do
        %Lens{all?: false, channel: %Channel{} = channel} ->
          channel =
            Enum.find(channels, &(&1.id == channel.id)) ||
              Channel.by_id!(channel.id, load: [:build_problem?, :latest_release])

          summary(channel, selected_revision, previous, true)

        _ ->
          nil
      end

    summaries =
      channels
      |> Enum.map(fn channel ->
        revision = Map.fetch!(revisions, channel.id)

        if selected && selected.channel.id == channel.id &&
             get_in(selected.revision.id) == get_in(revision.id) do
          %{selected | package_rows: [], option_rows: []}
        else
          summary(channel, revision, previous, false)
        end
      end)
      |> Enum.sort_by(
        fn summary ->
          {if(summary.revision, do: DateTime.to_unix(summary.revision.released_at), else: -1),
           summary.channel.name}
        end,
        :desc
      )

    all? = match?(%Lens{all?: true}, lens)

    %__MODULE__{all?: all?, selected: selected, channels: summaries}
    |> personal(user, lens)
    |> recent(user)
  end

  defp selected_revision(%Lens{revision: %ChannelRevision{} = revision}, _revisions),
    do: ChannelRevision.get_by_id!(revision.id)

  defp selected_revision(%Lens{channel: %Channel{} = channel}, revisions) do
    case Map.fetch(revisions, channel.id) do
      {:ok, revision} -> revision
      :error -> ChannelRevision.latest_at!(channel.id)
    end
  end

  defp selected_revision(_lens, _revisions), do: nil

  defp summary(channel, nil, _previous, _preview?), do: %ChannelSummary{channel: channel}

  defp summary(channel, %ChannelRevision{} = revision, previous, preview?) do
    predecessor = Map.get(previous, revision.previous_channel_revision_id)
    package_status = comparison_status(predecessor, revision, :result)
    option_status = comparison_status(predecessor, revision, :options_result)
    packages = comparison(package_status, :packages, predecessor, revision, preview?)
    options = comparison(option_status, :options, predecessor, revision, preview?)

    %ChannelSummary{
      channel: channel,
      revision: revision,
      previous_revision: predecessor,
      status:
        if(package_status == :ready and option_status == :ready,
          do: :ready,
          else: package_status_for(package_status, option_status)
        ),
      package_status: package_status,
      option_status: option_status,
      package_counts: packages && packages.counts,
      option_counts: options && options.counts,
      package_rows: (packages && packages.results) || [],
      option_rows: (options && options.results) || []
    }
  end

  defp package_status_for(:first_revision, _), do: :first_revision
  defp package_status_for(_, _), do: :incomplete

  defp comparison_status(nil, _revision, _field), do: :first_revision

  defp comparison_status(%ChannelRevision{} = previous, %ChannelRevision{} = revision, field) do
    if Map.fetch!(previous, field) == :success and Map.fetch!(revision, field) == :success,
      do: :ready,
      else: :incomplete
  end

  defp comparison(:ready, kind, previous, revision, preview?) do
    apply(RevisionComparison, kind, [
      previous,
      revision,
      [preview: preview?, counts_only: not preview?]
    ])
  end

  defp comparison(_status, _kind, _previous, _revision, _preview?), do: nil

  defp personal(dashboard, nil, _lens), do: dashboard

  defp personal(dashboard, %User{} = user, lens) do
    notifications = Notification.for_user!(actor: user, page: [limit: 3])

    unread =
      Notification.for_user!(%{unread_only: true}, actor: user, page: [limit: 1, count: true])

    subscriptions =
      ChangeSubscription.dashboard_preview!(actor: user, page: [limit: 3, count: true])

    followed =
      Enum.map(subscriptions.results, fn subscription ->
        %FollowedChange{
          change: subscription.change,
          subscription: subscription,
          landed_in: landed_in(subscription.change, lens)
        }
      end)

    %{
      dashboard
      | notifications: notifications.results,
        unread_count: unread.count,
        followed: followed,
        followed_count: subscriptions.count
    }
  end

  defp landed_in(%Change{state: :merged} = change, %Lens{
         all?: false,
         channel: %Channel{} = channel
       }) do
    if Enum.any?(change.change_branches, &(&1.branch_name == channel.name)), do: channel.name
  end

  defp landed_in(_change, _lens), do: nil

  defp recent(%__MODULE__{all?: true} = dashboard, nil),
    do: %{dashboard | recent_changes: Change.dashboard_recent!()}

  defp recent(dashboard, _user), do: dashboard
end
