defmodule VerifiedBase do
  alias Nerves.System.MacOS.{BaseImage, BaseSpec, Files, HTTP}
  @repository "cocoa-xu/nerves_system_macos"
  @files Enum.map(BaseSpec.files() ++ ["nerves-base.json"], &Path.join("base.tart", &1)) ++
           ["inputs.json", "result.json"]

  def save(base, logs, result) do
    directory = directory(result)
    Files.absent!(directory)
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    Files.clone(base, Path.join(directory, "base.tart"))

    for name <- ~w(inputs.json result.json),
        do: File.cp!(Path.join(logs, name), Path.join(directory, name))

    hashes = Map.new(@files, &{&1, Files.sha256(Path.join(directory, &1))})
    Files.write_json(Path.join(directory, "sha256.json"), hashes)
    IO.puts("Saved verified CI base #{result["run_id"]}")
  end

  def restore(profile, run_id, root, logs) do
    directory = directory(Map.put(profile, "run_id", run_id))
    hashes = read_json(Path.join(directory, "sha256.json"))

    unless Enum.sort(Map.keys(hashes)) == Enum.sort(@files),
      do: raise("The saved base checksum record is incomplete")

    for name <- @files,
        do: BaseImage.verify_digest!(Path.join(directory, name), hashes[name])

    inputs = read_json(Path.join(directory, "inputs.json"))
    result = read_json(Path.join(directory, "result.json"))

    unless Map.delete(inputs, "tools") == profile and result["result"] == "passed" and
             result["macos"] == profile["macos"] and
             result["image_version"] == profile["image_version"] and result["run_id"] == run_id,
           do: raise("The saved CI base does not match the selected profile")

    verify_run!(result)
    Files.clone(Path.join(directory, "base.tart"), Path.join(root, "base.tart"))

    for name <- ~w(inputs.json result.json),
        do: File.cp!(Path.join(directory, name), Path.join(logs, name))

    IO.puts("Restored verified CI base #{run_id} from #{result["revision"]}")
  end

  def remove(result), do: File.rm_rf!(directory(result))

  defp verify_run!(result) do
    [run_id, attempt] = String.split(result["run_id"], "-")
    path = "/actions/runs/#{run_id}/attempts/#{attempt}"
    run = github!(path)

    unless run["head_sha"] == result["revision"] and run["status"] == "completed" and
             run["run_attempt"] == String.to_integer(attempt) and
             run["path"] == ".github/workflows/base-image.yml" and
             run["repository"]["full_name"] == @repository and
             run["actor"]["login"] == "cocoa-xu" and
             run["triggering_actor"]["login"] == "cocoa-xu" and
             run["event"] in ["push", "workflow_dispatch"],
           do: raise("The saved base must come from an owner-authorized CI run")

    jobs = github!(path <> "/jobs?per_page=100")

    passed =
      Enum.any?(jobs["jobs"], fn job ->
        job["name"] == "macOS #{BaseSpec.major(result)}" and
          job["head_sha"] == result["revision"] and
          Enum.any?(job["steps"], fn step ->
            step["name"] == "Build and verify macOS" and step["conclusion"] == "success"
          end)
      end)

    unless passed, do: raise("The original CI build and verification step did not pass")
  end

  defp github!(path) do
    response =
      HTTP.request(
        :get,
        "https://api.github.com/repos/#{@repository}" <> path,
        [{"accept", "application/vnd.github+json"}, {"user-agent", "nerves-system-macos"}],
        "",
        cacert: System.fetch_env!("NERVES_MACOS_CACERT"),
        timeout: 30_000
      )

    unless response.status == 200,
      do: raise("Could not verify the original CI run: HTTP #{response.status}")

    Jason.decode!(response.body)
  end

  defp directory(result) do
    run_id = result["run_id"]

    unless is_binary(run_id) and Regex.match?(~r/\A[1-9]\d*-[1-9]\d*\z/, run_id),
      do: raise("Expected a saved CI run ID and attempt")

    Path.join([
      Path.expand("~/.cache/nerves-system-macos/verified"),
      to_string(BaseSpec.major(result)),
      run_id
    ])
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()
end
