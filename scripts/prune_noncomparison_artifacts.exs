# One-off prune of write-only workflow run artifacts archived before trk-345.
# Since trk-345 only comparison.zip is cached per PR; this deletes every other
# object under artifacts/nixpkgs/pull_requests/ (diff-*, maintainers, eval
# stats, ...), keeping comparison.zip and the meta.etf sidecar.
#
# Without confirmation this is a dry run that only lists what would be deleted.
#
#   dev:  mix run scripts/prune_noncomparison_artifacts.exs --yes
#   prod: bin/tracker rpc 'System.put_env("PRUNE_CONFIRM", "yes"); Code.eval_file("scripts/prune_noncomparison_artifacts.exs")'

alias Tracker.Nixpkgs.S3Cache

prefix = "artifacts/nixpkgs/pull_requests/"
keep = ~w(comparison.zip meta.etf)

config = S3Cache.config() || raise "no :s3_cache config — set TRACKER_S3_* env vars"
req = S3Cache.s3_req(config)

list_page = fn continuation_token ->
  params =
    [{"list-type", 2}, {"prefix", prefix}] ++
      if continuation_token, do: [{"continuation-token", continuation_token}], else: []

  %{status: 200, body: %{"ListBucketResult" => result}} =
    Req.get!(req, url: "s3://#{config.bucket}", params: params, retry: false)

  contents = result |> Map.get("Contents", []) |> List.wrap()
  next = if result["IsTruncated"] == "true", do: result["NextContinuationToken"]
  {contents, next}
end

objects =
  Stream.resource(
    fn -> nil end,
    fn
      :done ->
        {:halt, nil}

      token ->
        {contents, next} = list_page.(token)
        {contents, next || :done}
    end,
    fn _ -> :ok end
  )

{keep_count, doomed} =
  Enum.reduce(objects, {0, []}, fn %{"Key" => key} = object, {kept, doomed} ->
    if Path.basename(key) in keep do
      {kept + 1, doomed}
    else
      {kept, [{key, String.to_integer(object["Size"])} | doomed]}
    end
  end)

doomed = Enum.reverse(doomed)
doomed_bytes = doomed |> Enum.map(&elem(&1, 1)) |> Enum.sum()
gib = Float.round(doomed_bytes / 1024 ** 3, 2)

IO.puts("Kept objects (comparison.zip / meta.etf): #{keep_count}")
IO.puts("Objects to delete: #{length(doomed)} (#{gib} GiB)")

confirmed? = System.get_env("PRUNE_CONFIRM") == "yes" or "--yes" in System.argv()

if confirmed? do
  failed =
    doomed
    |> Enum.with_index(1)
    |> Enum.count(fn {{key, _size}, index} ->
      if rem(index, 500) == 0, do: IO.puts("  #{index}/#{length(doomed)}")
      S3Cache.delete_object(config, key) == :error
    end)

  IO.puts("Deleted #{length(doomed) - failed} objects, #{failed} failures")
else
  for {key, _size} <- Enum.take(doomed, 20), do: IO.puts("  #{key}")
  if length(doomed) > 20, do: IO.puts("  ... #{length(doomed) - 20} more")

  IO.puts("""

  Dry run only — nothing deleted.
  Pass --yes (mix run) or set PRUNE_CONFIRM=yes (rpc) to execute.
  """)
end
