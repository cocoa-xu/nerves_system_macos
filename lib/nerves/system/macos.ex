defmodule Nerves.System.MacOS do
  @moduledoc """
  Builds Nerves system artifacts for macOS guests on Apple silicon.

  System packages select this platform and `Nerves.Artifact.BuildRunners.Local`.
  Configure `:base_spec` to select a base and `:otp_root` for its native runtime.
  """

  @behaviour Nerves.Package.Platform
  @behaviour Nerves.Artifact.BuildRunner

  alias Nerves.System.MacOS.{Artifact, BaseSpec, Config, Environment}

  @impl true
  def bootstrap(_platform) do
    case System.get_env("NERVES_SYSTEM") do
      nil ->
        {:error, "NERVES_SYSTEM is not set"}

      path ->
        with %{platform: __MODULE__} = package <- Nerves.Env.system(),
             %{} = spec <- Config.validate_package!(package) do
          metadata = Artifact.read!(path)

          unless get_in(metadata, ["base", "fingerprint"]) == BaseSpec.fingerprint(spec),
            do: raise("The cached system does not match the selected base specification")
        end

        Environment.activate(path)
    end
  end

  @impl true
  def build(package, _toolchain, options) do
    protect(fn ->
      config = Config.new!(package.config[:platform_config] || [], package.path)
      path = build_path_link(package)

      if File.exists?(path) do
        checksum = Path.join(path, "CHECKSUM")

        unless File.regular?(checksum) and
                 String.trim(File.read!(checksum)) == Nerves.Artifact.checksum(package),
               do:
                 raise(
                   "An existing system artifact has no matching checksum; clean it explicitly before rebuilding"
                 )

        Artifact.read!(path)
      else
        Artifact.build(config, path, options)
      end

      {:ok, path}
    end)
  end

  @impl true
  def build_path_link(package) do
    path = Nerves.Artifact.build_path(package)

    if Config.validate_package!(package),
      do: path <> "-" <> String.downcase(Nerves.Artifact.checksum(package)),
      else: path
  end

  @impl true
  def archive(package, _toolchain, options) do
    protect(fn ->
      destination =
        Path.join(
          options[:path] || File.cwd!(),
          Nerves.Artifact.download_name(package) <> ".tar.gz"
        )

      Artifact.archive(build_path_link(package), destination)
      {:ok, destination}
    end)
  end

  @impl true
  def clean(package) do
    protect(fn ->
      Artifact.clean(build_path_link(package))
      Nerves.Artifact.Cache.delete(package)
      :ok
    end)
  end

  defp protect(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  end
end
