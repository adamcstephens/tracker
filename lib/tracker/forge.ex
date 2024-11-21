defmodule Tracker.Forge do
  use Ash.Domain

  resources do
    resource(Tracker.Forge.Repository.PullRequest)
  end
end
