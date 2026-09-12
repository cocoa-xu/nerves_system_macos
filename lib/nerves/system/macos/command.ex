defmodule Nerves.System.MacOS.Command do
  @moduledoc false
  @tail_limit 65_536

  def run!(command, arguments, options \\ []) do
    executable =
      System.find_executable(command) || raise "Required executable not found: #{command}"

    timeout = Keyword.get(options, :timeout, 60_000)

    environment =
      for {key, value} <- Keyword.get(options, :env, %{}),
          do: {to_charlist(key), to_charlist(value)}

    supervisor =
      System.find_executable("python3") || raise "Required executable not found: python3"

    runner = Nerves.System.MacOS.Files.priv("scripts/run-command.py")

    port =
      Port.open({:spawn_executable, to_charlist(supervisor)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        args: [runner, to_string(timeout), executable | arguments],
        env: environment,
        cd: to_charlist(options[:cd] || File.cwd!())
      ])

    deadline = System.monotonic_time(:millisecond) + timeout + 5_000

    try do
      collect(port, deadline, "", options)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect(port, deadline, output, options) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        if options[:log], do: File.write!(options[:log], data, [:append])
        if options[:stream], do: IO.binwrite(data)
        combined = output <> data

        tail =
          binary_part(
            combined,
            max(byte_size(combined) - @tail_limit, 0),
            min(byte_size(combined), @tail_limit)
          )

        collect(port, deadline, tail, options)

      {^port, {:exit_status, 0}} ->
        output

      {^port, {:exit_status, status}} ->
        if status in Keyword.get(options, :accept, []),
          do: output,
          else: raise("Command exited with status #{status}:\n#{output}")
    after
      remaining -> raise "Command exceeded its #{options[:timeout] || 60_000} ms deadline"
    end
  end
end
