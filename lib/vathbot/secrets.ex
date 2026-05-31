defmodule Vathbot.Secrets do
  @moduledoc """
  Holds decrypted Polymarket credentials in memory after password unlock.

  Crypto constants (must match pybuy/manage_secrets.py):
    - Format header: vathbot-secrets-v1
    - KDF: PBKDF2-HMAC-SHA256, 600_000 iterations, 32-byte key
    - Cipher: AES-256-GCM, 12-byte nonce, 16-byte salt
  """

  use GenServer

  @format_header "vathbot-secrets-v1"
  @pbkdf2_iterations 600_000
  @key_length 32
  @tag_length 16

  @required_keys ~w(POLYMARKET_PRIVATE_KEY POLYMARKET_FUNDER POLYMARKET_SIGNATURE_TYPE)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns whether credentials are still locked.
  """
  def locked? do
    GenServer.call(__MODULE__, :locked?)
  end

  @doc """
  Decrypts the configured secrets file and stores credentials in memory.
  """
  def unlock(password) when is_binary(password) do
    GenServer.call(__MODULE__, {:unlock, password})
  end

  @doc """
  Returns decrypted credentials or `{:error, :locked}`.
  """
  def credentials do
    GenServer.call(__MODULE__, :credentials)
  end

  @doc """
  Pure decrypt for tests. Returns `{:ok, plaintext}` or `{:error, reason}`.
  """
  def decrypt_file(path, password) when is_binary(path) and is_binary(password) do
    with {:ok, raw} <- File.read(path),
         {:ok, plaintext} <- decrypt_text(raw, password) do
      {:ok, plaintext}
    end
  end

  @doc false
  def parse_env(text) when is_binary(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.reduce(%{}, fn line, acc ->
      line = String.trim(line)

      cond do
        line == "" or String.starts_with?(line, "#") ->
          acc

        String.contains?(line, "=") ->
          [key, value] = String.split(line, "=", parts: 2)
          Map.put(acc, String.trim(key), String.trim(value))

        true ->
          acc
      end
    end)
  end

  @doc false
  def decrypt_text(raw, password) when is_binary(raw) and is_binary(password) do
    lines =
      raw
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    with [header, salt_b64, nonce_b64, ciphertext_b64] <- lines,
         true <- header == @format_header,
         {:ok, salt} <- Base.decode64(salt_b64),
         {:ok, nonce} <- Base.decode64(nonce_b64),
         {:ok, ciphertext_and_tag} <- Base.decode64(ciphertext_b64),
         key when is_binary(key) <- derive_key(password, salt),
         {:ok, plaintext} <- decrypt_aes_gcm(key, nonce, ciphertext_and_tag) do
      {:ok, plaintext}
    else
      _ -> {:error, :decrypt_failed}
    end
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    {:ok, %{locked: true, credentials: nil}}
  end

  @impl true
  def handle_call(:locked?, _from, state) do
    {:reply, state.locked, state}
  end

  def handle_call({:unlock, password}, _from, state) do
    path = secrets_file_path()

    with {:ok, plaintext} <- decrypt_file(path, password),
         credentials <- parse_env(plaintext),
         :ok <- validate_credentials(credentials) do
      {:reply, :ok, %{state | locked: false, credentials: credentials}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:credentials, _from, %{locked: true} = state) do
    {:reply, {:error, :locked}, state}
  end

  def handle_call(:credentials, _from, %{locked: false, credentials: credentials} = state) do
    {:reply, {:ok, credentials}, state}
  end

  defp secrets_file_path do
    Application.get_env(:vathbot, :secrets_file, "pybuy/secrets.env.enc")
    |> Path.expand()
  end

  defp validate_credentials(credentials) do
    missing =
      @required_keys
      |> Enum.reject(fn key -> Map.get(credentials, key) not in [nil, ""] end)

    if missing == [] do
      :ok
    else
      {:error, {:missing_keys, missing}}
    end
  end

  defp derive_key(password, salt) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, @pbkdf2_iterations, @key_length)
  end

  defp decrypt_aes_gcm(key, iv, ciphertext_and_tag) do
    tag_size = @tag_length
    ct_size = byte_size(ciphertext_and_tag) - tag_size

    if ct_size < 0 do
      {:error, :decrypt_failed}
    else
      <<ciphertext::binary-size(ct_size), tag::binary-size(tag_size)>> = ciphertext_and_tag

      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, <<>>, tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        _ -> {:error, :decrypt_failed}
      end
    end
  end
end
