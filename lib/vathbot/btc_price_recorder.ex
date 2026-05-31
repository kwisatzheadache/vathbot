defmodule Vathbot.BtcPriceRecorder do
  @moduledoc """
  Deprecated alias for `Vathbot.CryptoPriceRecorder`.
  """

  defdelegate start_link(opts \\ []), to: Vathbot.CryptoPriceRecorder
end
