defmodule Vathbot.ClobBook do
  @moduledoc """
  Public CLOB order book reads (no auth) for pricing integration tests.
  """

  @clob_host "https://clob.polymarket.com"

  @doc """
  Returns `{:ok, best_ask}` or `{:error, reason}` for a token id.
  """
  def best_ask(token_id) when is_binary(token_id) do
    with {:ok, book} <- fetch_book(token_id),
         {:ok, price} <- best_from_asks(book["asks"] || []) do
      {:ok, price}
    end
  end

  @doc false
  def fetch_book(token_id) when is_binary(token_id) do
    url = "#{@clob_host}/book?token_id=#{URI.encode(token_id)}"

    case Vathbot.HTTP.get(url) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, book} -> {:ok, book}
          {:error, reason} -> {:error, {:json_error, reason}}
        end

      {:ok, {{_, status, _}, _headers, body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp best_from_asks([]), do: {:error, :no_asks}

  defp best_from_asks(asks) do
    asks
    |> Enum.map(&parse_level_price/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> {:error, :no_asks}
      prices -> {:ok, Enum.min(prices)}
    end
  end

  defp parse_level_price(%{"price" => price}), do: parse_price(price)
  defp parse_level_price(%{price: price}), do: parse_price(price)
  defp parse_level_price(_), do: nil

  defp parse_price(price) when is_binary(price) do
    case Float.parse(price) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_price(price) when is_number(price), do: price * 1.0
  defp parse_price(_), do: nil
end
