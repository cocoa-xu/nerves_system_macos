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
    require_status!(authenticated_head(token, url), [404])
    Mix.shell().info("GHCR authentication passed and release tag #{tag} is unused")
  end

  def prepare(base, profile, revision, root, logs) do
    directory = Path.join(root, "publication")
    manifest_path = export(base, profile, revision, directory)
    digest = "sha256:" <> Files.sha256(manifest_path)

    spec =
      BaseSpec.validate!(%{
        "format" => 1,
        "image_version" => profile["image_version"],
        "macos" => profile["macos"],
        "source" => %{"type" => "prebuilt", "reference" => "ghcr.io/#{@repository}@#{digest}"}
      })

    Files.write_json(Path.join(logs, "base-spec.json"), spec)
    File.cp!(manifest_path, Path.join(logs, "oci-manifest.json"))

    File.write!(
      System.fetch_env!("GITHUB_OUTPUT"),
      "layout=#{Path.join(directory, "layout")}\nreference=ghcr.io/#{@repository}:#{BaseSpec.tag(profile)}\n",
      [:append]
    )
  end

  def verify(root, logs) do
    spec_path = Path.join(logs, "base-spec.json")
    spec = spec_path |> File.read!() |> Jason.decode!() |> BaseSpec.validate!()
    tag = BaseSpec.tag(spec)
    digest = "sha256:" <> Files.sha256(Path.join(logs, "oci-manifest.json"))

    unless spec["source"]["reference"] == "ghcr.io/#{@repository}@#{digest}",
      do: raise("The base specification and exported manifest do not match")

    wait_for_public_package!(@registry <> "/v2/#{@repository}/manifests/#{tag}", digest)
    File.rm_rf!(Path.join(root, "publication"))
    imported = Path.join(root, "downloaded.tart")
    Mix.shell().info("Downloading the published base anonymously and verifying a cold boot")
    BaseImage.prepare(spec_path, imported)
    File.cp!(imported <> ".log", Path.join(logs, "published-guest.log"))

    Files.write_json(Path.join(logs, "publication.json"), %{
      "tag" => tag,
      "reference" => spec["source"]["reference"],
      "anonymous_pull" => "passed"
    })

    Mix.shell().info("Published and verified #{spec["source"]["reference"]}")
  end

  def export(base, profile, revision, directory) do
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
          "org.opencontainers.image.revision" => revision,
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

    manifest_path = Path.join(directory, "v2/base/image/manifests/image")
    manifest = manifest_path |> File.read!() |> Jason.decode!()
    digest = Files.sha256(manifest_path)
    layout = Path.join(directory, "layout")
    blobs = Path.join(layout, "blobs/sha256")
    File.mkdir_p!(blobs)

    for descriptor <- Enum.uniq_by([manifest["config"] | manifest["layers"]], & &1["digest"]) do
      "sha256:" <> hash = descriptor["digest"]
      BaseSpec.digest!(hash)
      source = Path.join(directory, "v2/base/image/blobs/sha256:" <> hash)
      unless File.stat!(source).size == descriptor["size"], do: raise("OCI blob size mismatch")
      File.rename!(source, Path.join(blobs, hash))
    end

    File.cp!(manifest_path, Path.join(blobs, digest))
    Files.write_json(Path.join(layout, "oci-layout"), %{"imageLayoutVersion" => "1.0.0"})

    Files.write_json(Path.join(layout, "index.json"), %{
      "schemaVersion" => 2,
      "manifests" => [
        %{
          "mediaType" => @manifest_type,
          "digest" => "sha256:" <> digest,
          "size" => File.stat!(manifest_path).size,
          "annotations" => %{"org.opencontainers.image.ref.name" => "image"}
        }
      ]
    })

    manifest_path
  end

  defp authenticated_head(token, url) do
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
      :head,
      url,
      [{"authorization", "Bearer " <> token}, {"accept", @manifest_type}],
      "",
      options()
    )
  end

  defp wait_for_public_package!(url, digest) do
    Mix.shell().info(
      "Checking anonymous access; a new GHCR package may need its visibility set to public"
    )

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

        if rem(attempt, 4) == 1, do: Mix.shell().info("Waiting for anonymous GHCR access")
        Process.sleep(min(15_000, max(0, deadline - System.monotonic_time(:millisecond))))
        {:cont, nil}
      end
    end)
  end

  defp require_status!(%{status: status} = response, accepted) do
    unless status in accepted,
      do: raise("Unexpected HTTP status #{status}; expected #{inspect(accepted)}")

    response
  end

  defp options, do: [cacert: System.fetch_env!("NERVES_MACOS_CACERT")]
end
