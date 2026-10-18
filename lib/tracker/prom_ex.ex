defmodule Tracker.PromEx do
  use PromEx, otp_app: :tracker

  @impl PromEx
  def plugins do
    [Tracker.PromEx.GitHub, Tracker.PromEx.Oban]
  end
end
