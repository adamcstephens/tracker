defmodule Tracker.Nixpkgs.ChannelToolsTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.{Channel, ChannelRevision}

  test "heads expose the latest release and its revision, including unprocessed revisions" do
    channel = channel!("tool-heads")
    newest = revision!(channel, "newest", ~U[2026-04-02 10:00:00Z])
    revision!(channel, "older")
    empty = channel!("tool-empty")

    heads = Channel.list_channel_heads!(%{}, actor: actor()).results
    head = Enum.find(heads, &(&1.id == channel.id))
    assert head.latest_revision == "newest"
    assert head.latest_release == newest.released_at
    assert Enum.find(heads, &(&1.id == empty.id)).latest_revision == nil

    assert {:ok, output, _} =
             AshAi.Tools.execute(tool(:list_channel_heads), %{}, actor: actor())

    output = Jason.decode!(output)
    output_head = Enum.find(output["results"], &(&1["name"] == channel.name))

    assert Enum.sort(Map.keys(output_head)) ==
             ["display_name", "latest_release", "latest_revision", "name", "status"]
  end

  test "revision pages are newest-release-first, inclusive, isolated and resumable through tools" do
    channel = channel!("tool-history")
    other = channel!("tool-other")
    revision!(channel, "first")
    revision!(channel, "second")
    revision!(channel, "third", ~U[2026-04-02 10:00:00Z])
    revision!(other, "unrelated")

    tool = tool(:list_channel_revisions)

    args = %{
      "input" => %{
        "channel" => channel.name,
        "from" => "2020-01-01T00:00:00Z",
        "to" => "2100-01-01T00:00:00Z"
      },
      "limit" => 2
    }

    assert {:ok, page, _} = AshAi.Tools.execute(tool, args, actor: actor())
    page = Jason.decode!(page)
    assert Enum.map(page["results"], & &1["revision"]) == ["third", "second"]
    assert page["has_more"]
    assert is_binary(page["end_keyset"])

    assert {:ok, next, _} =
             AshAi.Tools.execute(
               tool,
               Map.put(args, "after", page["end_keyset"]),
               actor: actor()
             )

    next = Jason.decode!(next)

    assert Enum.map(next["results"], & &1["revision"]) == ["first"]
    refute next["has_more"]

    assert Map.keys(hd(next["results"])) |> Enum.sort() == [
             "released_at",
             "revision"
           ]

    assert {:ok, empty, _} =
             AshAi.Tools.execute(
               tool,
               put_in(args, ["input", "to"], "2021-01-01T00:00:00Z"),
               actor: actor()
             )

    empty = Jason.decode!(empty)

    assert empty["results"] == []
  end

  test "revision windows include exact release boundaries" do
    channel = channel!("tool-boundaries")
    revision!(channel, "before", ~U[2026-03-31 10:00:00Z])
    selected = revision!(channel, "selected")
    revision!(channel, "after", ~U[2026-04-02 10:00:00Z])

    page =
      ChannelRevision.list_channel_revisions!(
        %{channel: channel.name, from: selected.released_at, to: selected.released_at},
        actor: actor()
      )

    assert Enum.map(page.results, & &1.revision) == ["selected"]
  end

  test "new actions require an actor" do
    assert {:error, %Ash.Error.Forbidden{}} = Channel.list_channel_heads()

    assert {:error, %Ash.Error.Forbidden{}} =
             ChannelRevision.list_channel_revisions(%{
               channel: "missing",
               from: ~U[2020-01-01 00:00:00Z],
               to: ~U[2100-01-01 00:00:00Z]
             })
  end

  defp tool(name) do
    Enum.find(AshAi.exposed_tools(otp_app: :tracker, actor: actor()), &(&1.name == name))
  end

  defp actor, do: %Tracker.Accounts.User{id: Ash.UUID.generate()}

  defp channel!(name) do
    Channel.create!(%{name: name, display_name: name, status: :active, is_stable: false})
  end

  defp revision!(%Channel{} = channel, hash, released_at \\ ~U[2026-04-01 10:00:00Z]) do
    ChannelRevision.create!(%{
      channel_id: channel.id,
      revision: hash,
      released_at: released_at
    })
  end
end
