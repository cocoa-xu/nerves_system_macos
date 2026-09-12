defmodule Nerves.System.MacOS.HTTP do
  @moduledoc false

  def download(url, path, options, redirects \\ 3) do
    uri = URI.parse(url)

    unless uri.scheme == "https" or
             (options[:insecure] and uri.scheme == "http" and uri.host == "127.0.0.1"),
           do: raise("Downloads require HTTPS; HTTP is limited to loopback tests")

    if uri.userinfo, do: raise("Credentials in download URLs are not supported")
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    deadline = options[:deadline] || System.monotonic_time(:millisecond) + 300_000
    timeout = min(300_000, deadline - System.monotonic_time(:millisecond))
    if timeout <= 0, do: raise("Download deadline exceeded")

    ssl =
      if uri.scheme == "https" do
        ca = options[:cacert] || raise("Set NERVES_MACOS_CACERT to an explicit PEM CA bundle")
        unless File.regular?(ca), do: raise("Expected a PEM CA file: #{ca}")

        [
          verify: :verify_peer,
          cacertfile: to_charlist(ca),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      else
        []
      end

    headers =
      for {key, value} <- options[:headers] || [], do: {to_charlist(key), to_charlist(value)}

    limit = Keyword.fetch!(options, :max_bytes)
    unless is_integer(limit) and limit > 0, do: raise("Download size limit must be positive")
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".download-#{System.unique_integer([:positive])}"

    try do
      result = request(url, temporary, headers, ssl, timeout, deadline, limit)

      case result do
        %{status: 200} ->
          File.rename!(temporary, path)
          result

        %{status: status, headers: response_headers}
        when status in [301, 302, 303, 307, 308] ->
          if redirects == 0, do: raise("Too many download redirects")
          next = URI.merge(url, Map.fetch!(response_headers, "location")) |> URI.to_string()
          next_uri = URI.parse(next)

          if uri.scheme == "https" and next_uri.scheme != "https",
            do: raise("Refusing an HTTPS downgrade")

          options =
            if {uri.scheme, uri.host, uri.port} == {next_uri.scheme, next_uri.host, next_uri.port},
              do: options,
              else:
                Keyword.update(
                  options,
                  :headers,
                  [],
                  &Enum.reject(&1, fn {key, _} -> String.downcase(key) == "authorization" end)
                )

          download(next, path, Keyword.put(options, :deadline, deadline), redirects - 1)

        _ ->
          result
      end
    after
      File.rm(temporary)
    end
  end

  defp request(url, path, headers, ssl, timeout, deadline, limit) do
    File.open!(path, [:write, :binary], fn file ->
      {:ok, request} =
        :httpc.request(
          :get,
          {to_charlist(url), headers},
          [
            ssl: ssl,
            timeout: timeout,
            connect_timeout: min(timeout, 15_000),
            autoredirect: false
          ],
          sync: false,
          stream: {:self, :once},
          max_body_size: limit,
          # Separate connections keep concurrent requests' body limits independent.
          socket_opts: [nodelay: true]
        )

      try do
        receive_body(request, file, deadline, limit, nil, 0, :crypto.hash_init(:sha256))
      after
        :httpc.cancel_request(request)
      end
    end)
  end

  defp receive_body(request, file, deadline, limit, handler, size, digest) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:http, {^request, :stream_start, _headers, pid}} ->
        :httpc.stream_next(pid)
        receive_body(request, file, deadline, limit, pid, size, digest)

      {:http, {^request, :stream, data}} ->
        size = size + byte_size(data)
        if size > limit, do: raise("Download exceeds its declared size limit")
        :ok = IO.binwrite(file, data)
        :httpc.stream_next(handler)

        receive_body(
          request,
          file,
          deadline,
          limit,
          handler,
          size,
          :crypto.hash_update(digest, data)
        )

      {:http, {^request, :stream_end, headers}} ->
        %{
          status: 200,
          headers: headers(headers),
          size: size,
          sha256: digest |> :crypto.hash_final() |> Base.encode16(case: :lower)
        }

      {:http, {^request, {{_, status, _}, headers, _body}}} ->
        %{status: status, headers: headers(headers)}

      {:http, {^request, {:error, reason}}} ->
        raise("Download failed: #{inspect(reason)}")
    after
      remaining -> raise("Download deadline exceeded")
    end
  end

  defp headers(values),
    do:
      Map.new(values, fn {key, value} ->
        {key |> to_string() |> String.downcase(), to_string(value)}
      end)
end
