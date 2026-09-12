defmodule Nerves.System.MacOS.Files do
  @moduledoc false
  alias Nerves.System.MacOS.Command

  def priv(path), do: Path.join(to_string(:code.priv_dir(:nerves_system_macos)), path)
  def unique, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  def absent!(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _ -> raise "Refusing to replace existing path: #{path}"
    end
  end

  def regular!(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :ok
      _ -> raise "Expected a regular file: #{path}"
    end
  end

  def clone(source, destination) do
    absent!(destination)
    Command.run!("/bin/cp", ["-cR", source, destination], timeout: 300_000)
  end

  def write_json(path, value) do
    File.write!(path, Jason.encode_to_iodata!(value, pretty: true))
  end

  def sha256(path) do
    regular!(path)

    Command.run!("/usr/bin/shasum", ["-a", "256", "--", path], timeout: 300_000)
    |> String.slice(0, 64)
  end

  def host! do
    unless :os.type() == {:unix, :darwin}, do: raise("System builds require macOS")

    unless String.trim(Command.run!("uname", ["-m"])) == "arm64",
      do: raise("System builds require Apple silicon")
  end
end
