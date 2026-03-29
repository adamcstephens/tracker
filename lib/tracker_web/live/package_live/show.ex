defmodule TrackerWeb.PackageLive.Show do
  use TrackerWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@package.attribute}
      <:subtitle>Package details</:subtitle>
    </.header>

    <.list>
      <:item title="Id">{@package.id}</:item>

      <:item title="Attribute">{@package.attribute}</:item>
    </.list>

    <h2 class="mt-11 text-lg font-semibold leading-8 text-zinc-800">Revisions</h2>

    <.table :if={@package.revisions != []} id="revisions" rows={@package.revisions}>
      <:col :let={rev} label="Version">{rev.version}</:col>
      <:col :let={rev} label="Channel">{rev.channel_revision.channel}</:col>
      <:col :let={rev} label="Revision">
        <.revision_link revision={rev.channel_revision.revision} />
      </:col>
    </.table>

    <p :if={@package.revisions == []} class="mt-4 text-sm text-zinc-500">
      No revisions found.
    </p>

    <.back navigate={~p"/packages"}>Back to packages</.back>
    """
  end

  defp revision_link(assigns) do
    ~H"""
    <a
      href={"https://github.com/NixOS/nixpkgs/commit/#{@revision}"}
      target="_blank"
      rel="noopener noreferrer"
      title={@revision}
      class="text-blue-600 hover:underline font-mono"
    >
      {String.slice(@revision, 0, 7)}
    </a>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    package =
      Tracker.Nixpkgs.Package
      |> Ash.get!(id)
      |> Ash.load!(
        revisions:
          Tracker.Nixpkgs.PackageRevision
          |> Ash.Query.sort(inserted_at: :desc)
          |> Ash.Query.load(:channel_revision)
      )

    {:noreply,
     socket
     |> assign(:page_title, package.attribute)
     |> assign(:package, package)}
  end
end
