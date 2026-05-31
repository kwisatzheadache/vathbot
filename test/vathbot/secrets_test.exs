defmodule Vathbot.SecretsTest do
  use ExUnit.Case, async: true

  alias Vathbot.Secrets

  @fixture_plaintext """
  POLYMARKET_PRIVATE_KEY=0xabc123
  POLYMARKET_FUNDER=0xdef456
  POLYMARKET_SIGNATURE_TYPE=2
  """

  @password "test-password-roundtrip"

  setup do
    on_exit(fn ->
      if Process.whereis(Secrets), do: GenServer.stop(Secrets, :normal, :infinity)
    end)

    :ok
  end

  test "parse_env extracts key/value pairs" do
    assert Secrets.parse_env(@fixture_plaintext) == %{
             "POLYMARKET_PRIVATE_KEY" => "0xabc123",
             "POLYMARKET_FUNDER" => "0xdef456",
             "POLYMARKET_SIGNATURE_TYPE" => "2"
           }
  end

  test "decrypt_file rejects wrong password" do
    enc_path = write_python_encrypted_fixture(@fixture_plaintext, @password)

    assert {:error, :decrypt_failed} = Secrets.decrypt_file(enc_path, "wrong-password")
  end

  test "Python encrypt output can be decrypted by Elixir" do
    enc_path = write_python_encrypted_fixture(@fixture_plaintext, @password)

    assert {:ok, plaintext} = Secrets.decrypt_file(enc_path, @password)
    assert Secrets.parse_env(plaintext) == Secrets.parse_env(@fixture_plaintext)
  end

  test "locked? and credentials before unlock" do
    {:ok, _pid} = start_secrets()

    assert Secrets.locked?()
    assert Secrets.credentials() == {:error, :locked}
  end

  test "unlock with wrong password stays locked" do
    enc_path = write_python_encrypted_fixture(@fixture_plaintext, @password)
    Application.put_env(:vathbot, :secrets_file, enc_path)
    {:ok, _pid} = start_secrets()

    assert {:error, :decrypt_failed} = Secrets.unlock("wrong-password")
    assert Secrets.locked?()
  end

  test "unlock stores credentials in memory" do
    enc_path = write_python_encrypted_fixture(@fixture_plaintext, @password)
    Application.put_env(:vathbot, :secrets_file, enc_path)
    {:ok, _pid} = start_secrets()

    assert :ok = Secrets.unlock(@password)
    refute Secrets.locked?()

    assert {:ok, creds} = Secrets.credentials()
    assert creds["POLYMARKET_PRIVATE_KEY"] == "0xabc123"
    assert creds["POLYMARKET_FUNDER"] == "0xdef456"
    assert creds["POLYMARKET_SIGNATURE_TYPE"] == "2"
  end

  defp start_secrets do
    case Process.whereis(Secrets) do
      nil -> Secrets.start_link()
      _pid -> {:ok, Process.whereis(Secrets)}
    end
  end

  defp write_python_encrypted_fixture(plaintext, password) do
    input = Path.join(System.tmp_dir!(), "secrets_input_#{System.unique_integer([:positive])}.env")
    output = Path.join(System.tmp_dir!(), "secrets_output_#{System.unique_integer([:positive])}.enc")
    File.write!(input, plaintext)

    pybuy_dir = Application.get_env(:vathbot, :pybuy_dir)
    python = Application.get_env(:vathbot, :pybuy_python, "python3")

    env =
      System.get_env()
      |> Map.new()
      |> Map.put("VATHBOT_SECRETS_PASSWORD", password)

    {output_lines, 0} =
      System.cmd(
        python,
        ["manage_secrets.py", "encrypt", input, output],
        cd: pybuy_dir,
        env: env,
        stderr_to_stdout: true
      )

    on_exit(fn ->
      File.rm(input)
      File.rm(output)
    end)

    assert output_lines =~ "Encrypted"
    output
  end
end
