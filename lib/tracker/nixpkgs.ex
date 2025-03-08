defmodule Tracker.Nixpkgs do
  use Ash.Domain,
    otp_app: :tracker

  resources do
    resource Tracker.Nixpkgs.Package
  end

  def load_channel(channel \\ "nixos-unstable") do
    url = "https://channels.nixos.org/#{channel}/packages.json.br"

    {:ok, resp} = Req.get(url)

    resp.body
    |> ExBrotli.decompress!()
    |> Jason.decode!()
    |> Map.get("packages")
    |> Enum.map(fn {package, _} ->
      %{attribute: package}
    end)
    |> Ash.bulk_create(Tracker.Nixpkgs.Package, :create,
      batch_size: 15000,
      upsert?: true,
      upsert_identity: :unique_attribute,
      upsert_fields: :updated_at
    )
  end
end
