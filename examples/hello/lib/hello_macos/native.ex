defmodule HelloMacOS.Native do
  @on_load :load

  def load do
    :hello_macos |> :code.priv_dir() |> :filename.join(~c"hello_native") |> :erlang.load_nif(0)
  end

  def platform, do: :erlang.nif_error(:not_loaded)
end
