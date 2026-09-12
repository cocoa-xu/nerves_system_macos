defmodule HelloMacOS.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    boot = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    {~c"Darwin", ~c"arm64"} = platform = HelloMacOS.Native.platform()

    message =
      "Hello from macOS Nerves; #{inspect(platform)}; OTP #{System.otp_release()}; boot #{boot}"

    Logger.info(message)
    File.write!("boot.txt", message <> "\n", [:append])
    Supervisor.start_link([], strategy: :one_for_one, name: HelloMacOS.Supervisor)
  end
end
