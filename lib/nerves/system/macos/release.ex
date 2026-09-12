defmodule Nerves.System.MacOS.Release do
  @moduledoc "Release configuration for launchd-managed Nerves applications."
  alias Nerves.System.MacOS.{Artifact, Files, Runtime}

  def options do
    [
      include_erts: &erts/0,
      include_executables_for: [:unix],
      steps: [:assemble, &finish/1]
    ]
  end

  def erts do
    system = System.fetch_env!("NERVES_SYSTEM")
    metadata = Artifact.read!(system)
    Path.join([system, "runtime", "erts-" <> metadata["erts_version"]])
  end

  def finish(release) do
    system = Artifact.read!(System.fetch_env!("NERVES_SYSTEM"))

    unless to_string(release.erts_version) == system["erts_version"],
      do: raise("The release must include the system artifact's ERTS")

    Runtime.validate!(release.path)

    applications =
      for {app, mode} <- release.boot_scripts[:start], mode in [:permanent, :transient], do: app

    File.write!(
      Path.join(release.path, "nerves-applications.config"),
      :io_lib.format(~c"~p.~n", [applications])
    )

    Files.write_json(Path.join(release.path, "nerves-release.json"), %{
      "format" => 1,
      "name" => to_string(release.name),
      "version" => release.version,
      "system" => system
    })

    %{
      release
      | overlays: release.overlays ++ ["nerves-release.json", "nerves-applications.config"]
    }
  end
end
