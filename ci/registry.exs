defmodule BaseImageRegistry do
  require Record
  alias Nerves.System.MacOS.{BaseSpec, Files}
  Record.defrecordp(:request, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  def with_server(root, fun) do
    File.mkdir_p!(root)

    {:ok, server} =
      :inets.start(:httpd,
        port: 0,
        bind_address: {127, 0, 0, 1},
        server_name: ~c"localhost",
        server_root: to_charlist(root),
        document_root: to_charlist(root),
        modules: [__MODULE__],
        max_clients: 4,
        max_body_size: 64 * 1024 * 1024,
        max_client_body_chunk: 64 * 1024 * 1024,
        max_keep_alive_request: 100,
        keep_alive_timeout: 30
      )

    try do
      fun.("127.0.0.1:#{:httpd.info(server, [:port])[:port]}/base/image")
    after
      :inets.stop(:httpd, server)
    end
  end

  def unquote(:do)(info) do
    root = :httpd_util.lookup(request(info, :config_db), :document_root) |> to_string()
    uri = info |> request(:request_uri) |> to_string() |> URI.parse()
    method = info |> request(:method) |> to_string()

    body =
      case request(info, :entity_body) do
        {:last, body, _state} -> body
        body -> IO.iodata_to_binary(body)
      end

    {status, headers, response} = handle(method, uri, body, root)

    headers =
      [code: status, content_length: to_charlist(Integer.to_string(byte_size(response)))] ++
        Enum.map(headers, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)

    {:proceed, [{:response, {:response, headers, response}} | request(info, :data)]}
  end

  defp handle(method, %{path: "/v2/"}, _body, _root) when method in ["GET", "HEAD"],
    do: {200, [], ""}

  defp handle("POST", %{path: "/v2/base/image/blobs/uploads/"}, _body, root) do
    path = "/v2/base/image/blobs/uploads/" <> Files.unique()
    File.mkdir_p!(Path.dirname(root <> path))
    File.write!(root <> path, "")
    {202, [{"location", path}], ""}
  end

  defp handle(method, %{path: path} = uri, body, root) do
    case String.split(path, "/", trim: true) do
      ["v2", "base", "image", "blobs", "uploads", identifier]
      when method in ["PATCH", "PUT"] ->
        unless Regex.match?(~r/\A[a-f0-9]+\z/, identifier), do: raise("Invalid upload ID")
        file = root <> path
        Files.regular!(file)
        File.write!(file, body, [:append])

        if method == "PATCH" do
          {202, [{"location", path}], ""}
        else
          digest = "sha256:" <> Files.sha256(file)

          unless URI.decode_query(uri.query || "")["digest"] == digest,
            do: raise("The uploaded blob digest does not match")

          location = "/v2/base/image/blobs/" <> digest
          File.rename!(file, root <> location)
          {201, [{"location", location}, {"docker-content-digest", digest}], ""}
        end

      ["v2", "base", "image", "manifests", "image"] when method == "PUT" ->
        directory = Path.join(root, "v2/base/image/manifests")
        File.mkdir_p!(directory)
        File.write!(Path.join(directory, "image"), body)
        digest = "sha256:" <> Files.sha256(Path.join(directory, "image"))
        File.cp!(Path.join(directory, "image"), Path.join(directory, digest))
        {201, [{"docker-content-digest", digest}], ""}

      ["v2", "base", "image", kind, "sha256:" <> digest]
      when kind in ["blobs", "manifests"] and method == "HEAD" ->
        BaseSpec.digest!(digest)
        {if(File.regular?(root <> path), do: 200, else: 404), [], ""}

      _ ->
        {404, [], ""}
    end
  end
end
