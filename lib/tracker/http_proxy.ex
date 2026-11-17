defmodule Tracker.HTTPProxy do
  @moduledoc """
  Req plugin applying `no_proxy` exclusions to the effective destination on every request,
  including redirects. Entries support hostnames and domain suffixes, IP literals,
  optional ports (bracketed for IPv6), and `*`. No DNS resolution is performed.
  """

  def attach(%Req.Request{} = request) do
    request
    |> Req.Request.register_options([:no_proxy])
    |> Req.Request.append_request_steps(no_proxy: &apply_no_proxy/1)
  end

  def parse_no_proxy(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_entry/1)
  end

  defp parse_entry("*"), do: :all

  defp parse_entry(entry) do
    case :inet.parse_address(String.to_charlist(entry)) do
      {:ok, address} ->
        {{:ip, address}, nil}

      {:error, :einval} ->
        uri = URI.parse("//" <> String.trim_leading(entry, "."))

        key =
          case host_key(uri.host) do
            {:domain, domain} -> {:domain, domain, "." <> domain}
            ip -> ip
          end

        {key, uri.port}
    end
  end

  defp host_key(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ip, address}
      {:error, :einval} -> {:domain, String.downcase(host)}
    end
  end

  defp apply_no_proxy(%Req.Request{} = request) do
    original =
      Req.Request.get_private(request, :tracker_proxy_connect_options) ||
        Req.Request.get_option(request, :connect_options, [])

    entries = Req.Request.get_option(request, :no_proxy, [])
    host = host_key(request.url.host)
    port = request.url.port

    options =
      if Enum.any?(entries, &matches?(&1, host, port)) do
        Keyword.drop(original, [:proxy, :proxy_headers])
      else
        original
      end

    request
    |> Req.Request.put_private(:tracker_proxy_connect_options, original)
    |> Req.Request.merge_options(connect_options: options)
  end

  defp matches?(:all, _host, _port), do: true

  defp matches?({_host, expected_port}, _actual_host, port)
       when expected_port != nil and expected_port != port,
       do: false

  defp matches?({{:ip, address}, _port}, {:ip, address}, _actual_port), do: true

  defp matches?({{:domain, domain, suffix}, _port}, {:domain, host}, _actual_port) do
    host == domain or String.ends_with?(host, suffix)
  end

  defp matches?(_entry, _host, _port), do: false
end
