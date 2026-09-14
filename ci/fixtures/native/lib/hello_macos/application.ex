defmodule HelloMacOS.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    boot = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    {~c"Darwin", ~c"arm64"} = platform = HelloMacOS.Native.platform()
    version = System.get_env("RELEASE_VSN", "development")
    data_dir = System.get_env("NERVES_DATA_DIR", ".")

    if data_dir != "." and not File.regular?(Path.join(data_dir, ".nerves-volume")),
      do: raise("The persistent data volume is not mounted")

    message =
      "Hello from macOS Nerves; #{inspect(platform)}; OTP #{System.otp_release()}; release #{version}; boot #{boot}"

    Logger.info(message)
    File.write!(Path.join(data_dir, "boot.txt"), message <> "\n", [:append])
    Supervisor.start_link([], strategy: :one_for_one, name: HelloMacOS.Supervisor)
  end
end
