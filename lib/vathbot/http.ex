defmodule Vathbot.HTTP do
  @moduledoc """
  Thin wrapper around :httpc with sensible SSL defaults.
  """

  def get(url) when is_binary(url) do
    get(String.to_charlist(url))
  end

  def get(url) when is_list(url) do
    ssl_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    :httpc.request(:get, {url, []}, [{:timeout, 10_000} | ssl_opts], body_format: :binary)
  end
end
