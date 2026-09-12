defmodule Mix.Tasks.Nerves.Macos.Base do
  use Mix.Task
  @shortdoc "Selects, pins and prepares a macOS base"
  @moduledoc """
  Select macOS 15, 26 or 27 and an explicit image source.

      mix nerves.macos.base profiles
      mix nerves.macos.base lock --macos 26 --image-version 0.1.0 --source local --image DIRECTORY --output base.json
      mix nerves.macos.base lock --macos 26 --image-version 0.1.0 --source prebuilt --reference REGISTRY/IMAGE@sha256:DIGEST --output base.json
      mix nerves.macos.base lock --macos 26 --image-version 0.1.0 --source build --builder EXECUTABLE --repository DIRECTORY --recipe CONFIG --output base.json
      mix nerves.macos.base prepare --spec base.json --output DIRECTORY
      mix nerves.macos.base tag --spec base.json

  --image-version identifies the base release independently of macOS.
  Use --version and --build together to override the selected macOS profile.
  A build source pins a clean local Git checkout and the builder executable.
  Its CLI must accept build vanilla, --config, --repository and --target.
  All output paths must be new. No command publishes images.
  """
  alias Nerves.System.MacOS.{BaseImage, BaseSpec, Command, Files, VM}

  @impl true
  def run(["profiles"]) do
    Mix.shell().info(Jason.encode!(BaseSpec.profiles(), pretty: true))
  end

  def run(["lock" | args]) do
    {opts, []} =
      OptionParser.parse!(args,
        strict: [
          macos: :integer,
          image_version: :string,
          source: :string,
          image: :string,
          reference: :string,
          output: :string,
          version: :string,
          build: :string,
          builder: :string,
          repository: :string,
          recipe: :string
        ]
      )

    output = opts |> Keyword.fetch!(:output) |> Path.expand()
    Files.absent!(output)
    profile = opts |> Keyword.fetch!(:macos) |> BaseSpec.profile!()
    image_version = opts |> Keyword.fetch!(:image_version) |> BaseSpec.image_version!()

    if Keyword.has_key?(opts, :version) != Keyword.has_key?(opts, :build),
      do: Mix.raise("Specify both --version and --build when overriding a profile")

    version = opts[:version] || profile.version

    unless String.starts_with?(version, "#{profile.major}."),
      do: Mix.raise("The exact version must belong to the selected macOS major")

    spec =
      BaseSpec.validate!(%{
        "format" => 1,
        "image_version" => image_version,
        "macos" => %{
          "version" => version,
          "build" => opts[:build] || profile.build,
          "architecture" => "arm64"
        },
        "source" => source!(opts)
      })

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, Jason.encode_to_iodata!(spec, pretty: true), [:exclusive])
    Mix.shell().info("Wrote #{output}; base fingerprint #{BaseSpec.fingerprint(spec)}")
  end

  def run(["prepare" | args]) do
    {opts, []} = OptionParser.parse!(args, strict: [spec: :string, output: :string])
    spec = opts |> Keyword.fetch!(:spec) |> Path.expand()
    output = opts |> Keyword.fetch!(:output) |> Path.expand()
    Mix.shell().info(BaseImage.prepare(spec, output))
  end

  def run(["tag" | args]) do
    {opts, []} = OptionParser.parse!(args, strict: [spec: :string])
    spec = opts |> Keyword.fetch!(:spec) |> BaseSpec.read!()
    Mix.shell().info(BaseSpec.tag(spec))
  end

  def run(_), do: Mix.raise("Use profiles, lock, prepare or tag; see mix help nerves.macos.base")

  defp source!(opts) do
    case Keyword.fetch!(opts, :source) do
      "local" ->
        image = opts |> Keyword.fetch!(:image) |> Path.expand()
        VM.validate!(image)

        %{
          "type" => "local",
          "path" => image,
          "sha256" => Map.new(BaseSpec.files(), &{&1, Files.sha256(Path.join(image, &1))})
        }

      "prebuilt" ->
        %{"type" => "prebuilt", "reference" => Keyword.fetch!(opts, :reference)}

      "build" ->
        executable = opts |> Keyword.fetch!(:builder) |> Path.expand()
        repository = opts |> Keyword.fetch!(:repository) |> Path.expand()
        recipe = Keyword.fetch!(opts, :recipe)
        revision = Command.run!("git", ["rev-parse", "HEAD"], cd: repository) |> String.trim()
        BaseImage.verify_checkout!(repository, revision)
        Command.run!("git", ["ls-files", "--error-unmatch", "--", recipe], cd: repository)

        %{
          "type" => "build",
          "executable" => executable,
          "sha256" => Files.sha256(executable),
          "repository" => repository,
          "revision" => revision,
          "timeout_seconds" => 3600,
          "arguments" => [
            "build",
            "vanilla",
            "--config",
            recipe,
            "--repository",
            repository,
            "--target",
            "{vm}"
          ]
        }

      _ ->
        Mix.raise("Select local, prebuilt or build")
    end
  end
end
