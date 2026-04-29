defmodule Tracker.GitHub.GraphQL.PullRequest do
  @moduledoc """
  Summary of a pull request as returned by `Tracker.GitHub.GraphQL.fetch_prs/2`.
  """

  use TypedStruct

  typedstruct enforce: true do
    field :node_id, String.t()
    field :number, pos_integer()
    field :state, :draft | :open | :closed | :merged
    field :base_ref, String.t() | nil, enforce: false, default: nil
    field :head_ref, String.t() | nil, enforce: false, default: nil
    field :head_sha, String.t()
    field :title, String.t()
    field :updated_at, DateTime.t()
    field :closed_at, DateTime.t() | nil, enforce: false, default: nil
    field :merged_at, DateTime.t() | nil, enforce: false, default: nil
    field :merge_commit_sha, String.t() | nil, enforce: false, default: nil
    field :labels, [String.t()], default: []
  end
end
