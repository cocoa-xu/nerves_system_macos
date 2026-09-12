defmodule Mix.Tasks.Nerves.Macos.Otp do
  use Mix.Task
  @shortdoc "Downloads a checksum-pinned macOS OTP build"
  @moduledoc """
  Downloads an arm64 build from cocoa-xu/otp-build.

      mix nerves.macos.otp --version VERSION --sha256 DIGEST --output DIRECTORY --cacert PEM

  All options are required. The destination must not exist. TLS uses the supplied
  PEM trust store without consulting the macOS Keychain.
  """

  @impl true
  def run(args) do
    {options, positional} =
      OptionParser.parse!(args,
        strict: [version: :string, sha256: :string, output: :string, cacert: :string]
      )

    if positional != [], do: Mix.raise("Unexpected arguments")
    for key <- [:version, :sha256, :output, :cacert], do: Keyword.fetch!(options, key)

    unless Regex.match?(~r/^\d+(\.\d+)+$/, options[:version]),
      do: Mix.raise("An exact OTP version is required")

    unless Regex.match?(~r/^[a-fA-F0-9]{64}$/, options[:sha256]),
      do: Mix.raise("A SHA-256 digest is required")

    script = Nerves.System.MacOS.Files.priv("scripts/fetch-otp.py")

    Nerves.System.MacOS.Command.run!(
      "python3",
      [
        script,
        options[:version],
        String.downcase(options[:sha256]),
        Path.expand(options[:output]),
        Path.expand(options[:cacert])
      ],
      timeout: 600_000,
      stream: true
    )
  end
end
