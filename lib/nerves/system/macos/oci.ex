defmodule Nerves.System.MacOS.OCI do
  @moduledoc false
  alias Nerves.System.MacOS.{BaseSpec, HTTP}
  @manifest_type "application/vnd.oci.image.manifest.v1+json"
  @image_config_type "application/vnd.oci.image.config.v1+json"
  @config_type "application/vnd.cirruslabs.tart.config.v1"
  @disk_type "application/vnd.cirruslabs.tart.disk.v2"
  @nvram_type "application/vnd.cirruslabs.tart.nvram.v1"

  @version_label "org.opencontainers.image.version"

  def with_mirror(spec, root, fun) do
    source = spec["source"]
    {host, repository, digest} = BaseSpec.reference!(source["reference"])
    scheme = if source["insecure"], do: "http", else: "https"
    base = "#{scheme}://#{host}/v2/#{repository}"
    directory = Path.join(root, "registry")
    manifest_path = Path.join(directory, "v2/base/image/manifests/sha256:" <> digest)

    options = [
      cacert: System.get_env("NERVES_MACOS_CACERT"),
      insecure: source["insecure"] == true,
      deadline: System.monotonic_time(:millisecond) + 3_600_000,
      headers: [{"accept", @manifest_type}],
      max_bytes: 5_000_000
    ]

    result = HTTP.download(base <> "/manifests/sha256:" <> digest, manifest_path, options)

    options =
      if result.status == 401 do
        token = token!(result.headers["www-authenticate"], directory, options)
        Keyword.update!(options, :headers, &[{"authorization", "Bearer " <> token} | &1])
      else
        options
      end

    result =
      if result.status == 401,
        do: HTTP.download(base <> "/manifests/sha256:" <> digest, manifest_path, options),
        else: result

    unless result.status == 200 and result.sha256 == digest,
      do: raise("OCI manifest status or SHA-256 does not match")

    manifest = manifest_path |> File.read!() |> Jason.decode!()
    descriptors = descriptors!(manifest)
    config = manifest["config"]
    download_blob!(base, directory, config, options)
    verify_version!(config, directory, spec["image_version"])
    remaining = Enum.reject(descriptors, &(&1["digest"] == config["digest"]))
    IO.puts("Downloading #{length(remaining)} pinned OCI blobs")

    remaining
    |> Task.async_stream(
      fn descriptor ->
        try do
          download_blob!(base, directory, descriptor, options)
        rescue
          error -> {:error, Exception.message(error)}
        end
      end,
      max_concurrency: 2,
      timeout: 3_600_000,
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      {:ok, :ok} -> :ok
      other -> raise("OCI transfer failed: #{inspect(other)}")
    end)

    {:ok, server} =
      :inets.start(:httpd,
        port: 0,
        bind_address: {127, 0, 0, 1},
        server_name: ~c"localhost",
        server_root: to_charlist(directory),
        document_root: to_charlist(directory),
        modules: [:mod_alias, :mod_get, :mod_head],
        mime_types: [],
        max_clients: 4
      )

    try do
      port = :httpd.info(server, [:port])[:port]
      fun.("127.0.0.1:#{port}/base/image@sha256:#{digest}")
    after
      :inets.stop(:httpd, server)
    end
  end

  defp download_blob!(base, directory, descriptor, options) do
    target = Path.join(directory, "v2/base/image/blobs/" <> descriptor["digest"])

    result =
      HTTP.download(
        base <> "/blobs/" <> descriptor["digest"],
        target,
        Keyword.put(options, :max_bytes, descriptor["size"])
      )

    unless result.status == 200 and result.size == descriptor["size"] and
             "sha256:" <> result.sha256 == descriptor["digest"],
           do: raise("OCI blob status, size or SHA-256 does not match")

    :ok
  end

  defp verify_version!(descriptor, directory, expected) do
    path = Path.join(directory, "v2/base/image/blobs/" <> descriptor["digest"])
    config = path |> File.read!() |> Jason.decode!()
    actual = get_in(config, ["config", "Labels", @version_label])

    unless actual == expected,
      do: raise("OCI image version #{inspect(actual)} does not match #{inspect(expected)}")
  end

  defp token!(challenge, root, options) do
    unless is_binary(challenge) and String.starts_with?(String.downcase(challenge), "bearer "),
      do: raise("The registry must support anonymous Bearer authentication")

    fields =
      Map.new(Regex.scan(~r/([a-z_]+)="([^"]*)"/i, challenge), fn [_, key, value] ->
        {String.downcase(key), value}
      end)

    realm = fields |> Map.fetch!("realm") |> URI.parse()
    query = Map.merge(URI.decode_query(realm.query || ""), Map.take(fields, ["service", "scope"]))
    url = URI.to_string(%{realm | query: URI.encode_query(query)})
    path = Path.join(root, "token.json")

    try do
      result =
        HTTP.download(
          url,
          path,
          options |> Keyword.put(:headers, []) |> Keyword.put(:max_bytes, 65_536)
        )

      unless result.status == 200, do: raise("Anonymous registry authentication failed")
      value = path |> File.read!() |> Jason.decode!()
      token = value["token"] || value["access_token"]

      unless is_binary(token) and token != "",
        do: raise("The registry returned no anonymous token")

      token
    after
      File.rm(path)
    end
  end

  defp descriptors!(manifest) do
    layers = manifest["layers"]

    unless manifest["schemaVersion"] == 2 and is_list(layers) and layers != [],
      do: raise("Unsupported OCI manifest")

    unless get_in(manifest, ["config", "mediaType"]) == @image_config_type,
      do: raise("Unsupported OCI image config")

    unless manifest["config"]["size"] in 1..5_000_000,
      do: raise("OCI image config exceeds its size limit")

    unless Enum.count(layers, &(&1["mediaType"] == @config_type)) == 1 and
             Enum.count(layers, &(&1["mediaType"] == @nvram_type)) == 1 and
             Enum.any?(layers, &(&1["mediaType"] == @disk_type)) and
             Enum.all?(layers, &(&1["mediaType"] in [@config_type, @disk_type, @nvram_type])),
           do:
             raise(
               "A prebuilt base must use a standalone Tart raw disk, not stacked or legacy layers"
             )

    descriptors = Enum.uniq_by([manifest["config"] | layers], & &1["digest"])

    for descriptor <- descriptors do
      digest = descriptor["digest"]

      unless is_binary(digest) and String.starts_with?(digest, "sha256:"),
        do: raise("An OCI blob has no SHA-256 digest")

      BaseSpec.digest!(String.replace_prefix(digest, "sha256:", ""))

      unless is_integer(descriptor["size"]) and descriptor["size"] in 1..2_147_483_648,
        do: raise("An OCI blob has an unsupported size")
    end

    descriptors
  end
end
