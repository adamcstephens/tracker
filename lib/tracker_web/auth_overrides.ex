defmodule TrackerWeb.AuthOverrides do
  use AshAuthentication.Phoenix.Overrides

  override AshAuthentication.Phoenix.SignInLive do
    set :root_class, "container"
  end

  override AshAuthentication.Phoenix.Components.Banner do
    set :image_url, nil
    set :dark_image_url, nil
    set :href_url, nil
    set :text, "Sign in to Tracker"
    set :root_class, "sign-in-banner"
    set :text_class, "sign-in-banner-text"
  end

  override AshAuthentication.Phoenix.Components.SignIn do
    set :root_class, ""
    set :strategy_class, ""
  end

  override AshAuthentication.Phoenix.Components.OAuth2 do
    set :root_class, "sign-in-oauth"
    set :link_class, ""
    set :icon_class, ""
  end
end
