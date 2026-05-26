defmodule Vathbot.Types.Signal do
  @moduledoc """
  Trading signal emitted by a model for the order handler to process.
  """

  @enforce_keys [:type, :slug, :outcome, :amount_usd, :price, :recorded_at, :model]
  defstruct [
    :type,
    :slug,
    :outcome,
    :amount_usd,
    :price,
    :recorded_at,
    :model,
    :best_bid,
    :spread,
    :ask_or_bid
  ]

  @type t :: %__MODULE__{
          type: :buy,
          slug: String.t(),
          outcome: String.t(),
          amount_usd: float(),
          price: float(),
          recorded_at: integer(),
          model: String.t(),
          best_bid: float() | nil,
          spread: float() | nil,
          ask_or_bid: :ask | :bid | nil
        }

  def to_map(%__MODULE__{} = signal) do
    %{
      "type" => Atom.to_string(signal.type),
      "slug" => signal.slug,
      "outcome" => signal.outcome,
      "amount_usd" => signal.amount_usd,
      "price" => signal.price,
      "recorded_at" => signal.recorded_at,
      "model" => signal.model,
      "best_bid" => signal.best_bid,
      "spread" => signal.spread,
      "ask_or_bid" =>
        case signal.ask_or_bid do
          nil -> nil
          side -> Atom.to_string(side)
        end
    }
  end
end
