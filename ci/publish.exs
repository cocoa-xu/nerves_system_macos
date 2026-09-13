Code.require_file("registry.exs", __DIR__)

defmodule BaseImagePublication do
  alias Nerves.System.MacOS.{BaseImage, BaseSpec, Command, Files, HTTP, VM}
  @repository "cocoa-xu/nerves_system_macos"
  @registry "https://ghcr.io"
  @manifest_type "application/vnd.oci.image.manifest.v1+json"

  def check(profile) do
    token = System.fetch_env!("GH_TOKEN")
    System.delete_env("GH_TOKEN")
    tag = BaseSpec.tag(profile)
    url = @registry <> "/v2/#{@repository}/manifests/#{tag}"
    require_status!(registry_request(token, :head, url), [404])
    IO.puts("GHCR authentication passed and release tag #{tag} is unused")
  end

  def publish(base, profile, root, logs) do
    token = System.fetch_env!("GH_TOKEN")
    System.delete_env("GH_TOKEN")
    tag = BaseSpec.tag(profile)
    manifest_url = @registry <> "/v2/#{@repository}/manifests/#{tag}"
    require_status!(registry_request(token, :head, manifest_url), [404])
    directory = Path.join(root, "publication")
    manifest_path = export(base, profile, directory)
    manifest = manifest_path |> File.read!() |> Jason.decode!()
    digest = "sha256:" <> Files.sha256(manifest_path)
    descriptors = Enum.uniq_by([manifest["config"] | manifest["layers"]], & &1["digest"])

    for {descriptor, index} <- Enum.with_index(descriptors, 1) do
      upload_blob(directory, descriptor, token)
      IO.puts("Uploaded OCI blob #{index}/#{length(descriptors)}")
    end

    require_status!(registry_request(token, :head, manifest_url), [404])

    response =
      registry_request(token, :put, manifest_url, {:file, manifest_path}, @manifest_type)
      |> require_status!([201])

    unless response.headers["docker-content-digest"] == digest,
      do: raise("The registry returned a different manifest digest")

    spec =
      BaseSpec.validate!(%{
        "format" => 1,
        "image_version" => profile["image_version"],
        "macos" => profile["macos"],
        "source" => %{"type" => "prebuilt", "reference" => "ghcr.io/#{@repository}@#{digest}"}
      })

    spec_path = Path.join(logs, "base-spec.json")
    Files.write_json(spec_path, spec)
    File.cp!(manifest_path, Path.join(logs, "oci-manifest.json"))
    IO.puts("Published ghcr.io/#{@repository}:#{tag} at #{digest}")
    wait_for_public_package!(manifest_url, digest)
    File.rm_rf!(directory)
    imported = Path.join(root, "downloaded.tart")
    IO.puts("Downloading the published base anonymously and verifying a cold boot")
    BaseImage.prepare(spec_path, imported)
    File.cp!(imported <> ".log", Path.join(logs, "published-guest.log"))
    release = create_release(profile, spec, logs, token)

    Files.write_json(Path.join(logs, "publication.json"), %{
      "tag" => tag,
      "reference" => spec["source"]["reference"],
      "release" => release["html_url"],
      "prerelease" => release["prerelease"],
      "anonymous_pull" => "passed"
    })

    IO.puts("Published and verified #{release["html_url"]}")
  end

  def export(base, profile, directory) do
    BaseImageRegistry.with_server(directory, fn reference ->
      VM.with_copy(base, Path.dirname(directory), fn vm ->
        [host, _repository] = String.split(reference, "/", parts: 2)

        env =
          Map.merge(vm.env, %{
            "TART_REGISTRY_HOSTNAME" => host,
            "TART_REGISTRY_USERNAME" => "unused",
            "TART_REGISTRY_PASSWORD" => "unused"
          })

        labels = %{
          "org.opencontainers.image.source" => "https://github.com/#{@repository}",
          "org.opencontainers.image.version" => profile["image_version"],
          "org.opencontainers.image.revision" => System.fetch_env!("GITHUB_SHA"),
          "org.opencontainers.image.title" => "macOS #{profile["macos"]["version"]} base"
        }

        arguments =
          [
            "push",
            vm.name,
            reference <> ":image",
            "--insecure",
            "--concurrency",
            "2",
            "--chunk-size",
            "16"
          ] ++
            Enum.flat_map(labels, fn {key, value} -> ["--label", "#{key}=#{value}"] end)

        Command.run!("tart", arguments, env: env, timeout: 1_800_000, stream: true)
      end)
    end)

    Path.join(directory, "v2/base/image/manifests/image")
  end

  defp upload_blob(directory, descriptor, token) do
    digest = descriptor["digest"]
    "sha256:" <> hash = digest
    BaseSpec.digest!(hash)
    path = Path.join(directory, "v2/base/image/blobs/" <> digest)
    unless File.stat!(path).size == descriptor["size"], do: raise("OCI blob size mismatch")
    url = @registry <> "/v2/#{@repository}/blobs/#{digest}"

    case registry_request(token, :head, url) |> require_status!([200, 404]) do
      %{status: 200} ->
        :ok

      %{status: 404} ->
        upload_start = @registry <> "/v2/#{@repository}/blobs/uploads/"
        response = registry_request(token, :post, upload_start)
        require_status!(response, [202])
        location = URI.merge(upload_start, Map.fetch!(response.headers, "location"))

        unless location.scheme == "https" and location.host == "ghcr.io" and location.port == 443 and
                 is_nil(location.userinfo) and is_nil(location.fragment),
               do: raise("The registry upload location must use the HTTPS GHCR origin")

        digest_parameter = "digest=" <> URI.encode_www_form(digest)

        query =
          case location.query do
            value when value in [nil, ""] -> digest_parameter
            value -> value <> "&" <> digest_parameter
          end

        upload_url = URI.to_string(%{location | query: query})

        uploaded =
          registry_request(token, :put, upload_url, {:file, path}) |> require_status!([201])

        unless uploaded.headers["docker-content-digest"] == digest,
          do: raise("The registry returned a different blob digest")
    end
  end

  defp registry_request(
         token,
         method,
         url,
         body \\ "",
         content_type \\ "application/octet-stream"
       ) do
    credentials = System.fetch_env!("GITHUB_ACTOR") <> ":" <> token

    token_url =
      @registry <>
        "/token?" <>
        URI.encode_query(%{
          "service" => "ghcr.io",
          "scope" => "repository:#{@repository}:pull,push"
        })

    token =
      HTTP.request(
        :get,
        token_url,
        [{"authorization", "Basic " <> Base.encode64(credentials)}],
        "",
        options()
      )
      |> require_status!([200])
      |> Map.fetch!(:body)
      |> Jason.decode!()
      |> Map.fetch!("token")

    HTTP.request(
      method,
      url,
      [{"authorization", "Bearer " <> token}, {"accept", @manifest_type}],
      body,
      options() ++ [content_type: content_type, timeout: 600_000]
    )
  end

  defp wait_for_public_package!(url, digest) do
    IO.puts("Checking anonymous access; a new GHCR package may need its visibility set to public")
    deadline = System.monotonic_time(:millisecond) + 1_800_000
    options = options() ++ [timeout: 15_000]

    Enum.reduce_while(1..120, nil, fn attempt, _ ->
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("Set the GHCR package visibility to public before verification")

      response = HTTP.request(:get, url, [{"accept", @manifest_type}], "", options)

      response =
        if response.status == 401 do
          token_url =
            @registry <>
              "/token?" <>
              URI.encode_query(%{
                "service" => "ghcr.io",
                "scope" => "repository:#{@repository}:pull"
              })

          token = HTTP.request(:get, token_url, [], "", options)

          if token.status == 200 do
            token = Jason.decode!(token.body)["token"]

            HTTP.request(
              :get,
              url,
              [{"authorization", "Bearer " <> token}, {"accept", @manifest_type}],
              "",
              options
            )
          else
            token
          end
        else
          response
        end

      if response.status == 200 do
        actual = "sha256:" <> Base.encode16(:crypto.hash(:sha256, response.body), case: :lower)
        unless actual == digest, do: raise("The public manifest digest does not match")
        {:halt, :ok}
      else
        if attempt == 120,
          do: raise("Set the GHCR package visibility to public before verification")

        if rem(attempt, 4) == 1, do: IO.puts("Waiting for anonymous GHCR access")
        Process.sleep(min(15_000, max(0, deadline - System.monotonic_time(:millisecond))))
        {:cont, nil}
      end
    end)
  end

  defp create_release(profile, spec, logs, token) do
    tag = BaseSpec.tag(profile)
    reference = spec["source"]["reference"]

    body = """
    Blank arm64 macOS base with SSH and Command Line Tools.

    Account and password: `admin`. Language: English (United States). Keyboard: U.S.

    ```sh
    tart clone #{reference} macos-#{BaseSpec.major(spec)}
    ```

    Use the attached `base-spec.json` with `mix nerves.macos.base prepare`.
    The Nerves system, native example and two cold boots passed with OTP #{profile["otp"]["version"]}.
    The published image was downloaded anonymously and passed an independent blank-base boot.
    """

    payload =
      Jason.encode!(%{
        "tag_name" => tag,
        "target_commitish" => System.fetch_env!("GITHUB_SHA"),
        "name" =>
          "macOS #{profile["macos"]["version"]} (#{profile["macos"]["build"]}), image #{profile["image_version"]}",
        "body" => String.trim(body),
        "prerelease" => profile["prerelease"],
        "draft" => true
      })

    headers = [
      {"authorization", "Bearer " <> token},
      {"accept", "application/vnd.github+json"},
      {"user-agent", "nerves-system-macos"}
    ]

    response =
      HTTP.request(
        :post,
        "https://api.github.com/repos/#{@repository}/releases",
        headers,
        payload,
        options() ++ [content_type: "application/json"]
      )
      |> require_status!([201])

    release = Jason.decode!(response.body)
    upload_url = release["upload_url"] |> String.split("{") |> hd()

    uri = URI.parse(upload_url)

    unless uri.scheme == "https" and uri.host == "uploads.github.com" and uri.port == 443 and
             String.starts_with?(uri.path, "/repos/#{@repository}/releases/"),
           do: raise("Unexpected release upload host")

    for name <- ["base-spec.json", "inputs.json", "result.json", "oci-manifest.json"] do
      path = Path.join(logs, name)

      asset =
        HTTP.request(
          :post,
          upload_url <> "?name=" <> name,
          headers,
          {:file, path},
          options() ++ [content_type: "application/json"]
        )
        |> require_status!([201])
        |> Map.fetch!(:body)
        |> Jason.decode!()

      unless asset["state"] == "uploaded" and asset["size"] == File.stat!(path).size,
        do: raise("The release asset upload is incomplete")
    end

    payload =
      Jason.encode!(%{
        "draft" => false,
        "make_latest" => if(profile["prerelease"], do: "false", else: "true")
      })

    release =
      HTTP.request(
        :patch,
        "https://api.github.com/repos/#{@repository}/releases/#{release["id"]}",
        headers,
        payload,
        options() ++ [content_type: "application/json"]
      )
      |> require_status!([200])
      |> Map.fetch!(:body)
      |> Jason.decode!()

    unless release["draft"] == false and release["tag_name"] == tag and
             release["prerelease"] == profile["prerelease"],
           do: raise("The published release metadata does not match")

    release
  end

  defp require_status!(%{status: status} = response, accepted) do
    unless status in accepted,
      do: raise("Unexpected HTTP status #{status}; expected #{inspect(accepted)}")

    response
  end

  defp options, do: [cacert: System.fetch_env!("NERVES_MACOS_CACERT")]
end
