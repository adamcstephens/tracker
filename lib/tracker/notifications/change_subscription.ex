defmodule Tracker.Notifications.ChangeSubscription do
  @moduledoc """
  A user's subscription to a change's propagation. A nil `channel_id` means
  "any branch/channel"; a set `channel_id` scopes to propagation reaching that
  one channel.
  """

  use Ash.Resource,
    otp_app: :tracker,
    domain: Tracker.Notifications,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "change_subscriptions"
    repo Tracker.Repo

    references do
      reference :user, on_delete: :delete
      reference :change, on_delete: :delete
      reference :channel, on_delete: :delete
    end
  end

  code_interface do
    define :subscribe, args: [:change_id, {:optional, :channel_id}]
    define :find, args: [:change_id, {:optional, :channel_id}], not_found_error?: false
    define :destroy
    define :for_user
    define :subscribers_of_change, args: [:change_id, {:optional, :channel_id}]
  end

  actions do
    defaults [:read, :destroy]

    create :subscribe do
      description "Subscribe the actor to a change, optionally scoped to one channel."
      accept [:change_id, :channel_id]
      upsert? true
      upsert_identity :unique_change_subscription
      upsert_fields [:updated_at]

      change relate_actor(:user)
    end

    read :find do
      description "Fetch the actor's subscription to a change at the given channel scope, if any."
      get? true
      argument :change_id, :integer, allow_nil?: false
      argument :channel_id, :integer

      filter expr(
               change_id == ^arg(:change_id) and
                 ((is_nil(^arg(:channel_id)) and is_nil(channel_id)) or
                    channel_id == ^arg(:channel_id))
             )
    end

    read :for_user do
      description "List the actor's change subscriptions, newest first."
      prepare build(sort: [inserted_at: :desc])
    end

    read :subscribers_of_change do
      description """
      Change subscriptions matching a change for fan-out: any-branch (nil channel)
      subscriptions always match; channel-targeted subscriptions match the mapped channel.
      """

      argument :change_id, :integer, allow_nil?: false
      argument :channel_id, :integer

      filter expr(
               change_id == ^arg(:change_id) and
                 (is_nil(channel_id) or channel_id == ^arg(:channel_id))
             )
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if expr(not is_nil(^actor(:id)))
    end

    policy action_type([:read, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    integer_primary_key :id
    timestamps()
  end

  relationships do
    belongs_to :user, Tracker.Accounts.User, attribute_type: :uuid, allow_nil?: false
    belongs_to :change, Tracker.Nixpkgs.Change, attribute_type: :integer, allow_nil?: false
    belongs_to :channel, Tracker.Nixpkgs.Channel, attribute_type: :integer
  end

  calculations do
    calculate :propagated?, :boolean, __MODULE__.Propagated do
      load channel: [:name], change: [:base_ref, change_branches: [:branch_name]]
    end
  end

  defmodule Propagated do
    @moduledoc """
    Whether a subscription's target has been reached, relative to its scope: a
    channel-scoped subscription once the change is present on that channel, an
    any-branch subscription once the change has propagated everywhere.
    """
    use Ash.Resource.Calculation

    alias Tracker.Nixpkgs.Propagation

    @impl true
    def calculate(subscriptions, _opts, _context) do
      Enum.map(subscriptions, fn sub ->
        branches = Enum.map(sub.change.change_branches, & &1.branch_name)

        case sub.channel do
          nil -> Propagation.complete?(sub.change.base_ref, branches)
          channel -> channel.name in branches
        end
      end)
    end
  end

  identities do
    identity :unique_change_subscription, [:user_id, :change_id, :channel_id] do
      nils_distinct? false
    end
  end

  @doc """
  Subscribes the change's author to it at the any-branch scope, if a user with
  that GitHub id has opted in to authored auto-subscribe.
  """
  @spec auto_subscribe_author(integer(), integer() | nil) :: :ok
  def auto_subscribe_author(change_id, author_github_id) do
    auto_subscribe(
      change_id,
      author_github_id,
      &Tracker.Accounts.User.authored_auto_subscriber!/2
    )
  end

  @doc """
  Subscribes the change's merger to it at the any-branch scope, if a user with
  that GitHub id has opted in to merged auto-subscribe.
  """
  @spec auto_subscribe_merger(integer(), integer() | nil) :: :ok
  def auto_subscribe_merger(change_id, merged_by_github_id) do
    auto_subscribe(
      change_id,
      merged_by_github_id,
      &Tracker.Accounts.User.merged_auto_subscriber!/2
    )
  end

  # The lookup runs unauthorized: the User read policy forbids everything
  # outside AshAuthentication's bypass, and ingestion has no actor of its own.
  # The subscribe itself is authorized as the user it belongs to.
  defp auto_subscribe(_change_id, nil, _lookup), do: :ok

  defp auto_subscribe(change_id, github_id, lookup) do
    case lookup.(github_id, authorize?: false) do
      nil ->
        :ok

      user ->
        subscribe!(change_id, nil, actor: user)
        :ok
    end
  end
end
