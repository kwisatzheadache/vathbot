# Agent Implementation Spec: Encrypted Secrets and Password-Gated Live Trading

## Objective

Implement secure credential handling for `vathbot` and `pybuy`.

The goal is to remove plaintext `.env` files from runtime use, store Polymarket credentials in a password-encrypted file, and require an interactive password unlock before any live order can be posted. 

## Background

Polymarket credentials currently live in plaintext at:

```text
pybuy/.env
```

The affected credentials are:

```text
POLYMARKET_PRIVATE_KEY
POLYMARKET_FUNDER
POLYMARKET_SIGNATURE_TYPE
```

`vathbot` enables live trading via:

```text
VATHBOT_EXECUTE_TRADES=1
```

When live trading is enabled, `vathbot` invokes:

```text
pybuy/place_order.py
```

That script currently loads credentials through `python-dotenv`.

After a suspected key compromise, credential handling must be changed so that:

- No plaintext `.env` file is required or read at runtime.
- Live trading requires an interactive password unlock.
- Credentials are stored in a password-encrypted env file.
- Decrypted credentials exist in memory only.
- Signal logging, backtesting, parquet recording, and dry-run orders do not require credentials or a password.

## Target Architecture

```text
pybuy/secrets.env.enc          # encrypted blob on disk, chmod 600
         │
         ▼
password prompt once per mix run session
hidden terminal input
         │
         ▼
Vathbot.Secrets GenServer      # decrypted key/value map in memory only
         │
         ▼
POLYMARKET_* passed as subprocess env
not CLI args
         │
         ▼
pybuy/place_order.py           # uses env vars; no plaintext .env fallback
```

## Security Invariants

The implementation must preserve these invariants:

- Plaintext `pybuy/.env` must not be read at runtime after migration.
- Decrypted secrets must never be written back to disk.
- No decrypted temp files are allowed.
- Password entry must use hidden terminal input, such as `IO.getpass/1` or equivalent.
- If live trading is enabled and unlock fails, the system must fail closed and refuse to post orders.
- Dry-run and signal-only modes must not prompt for a password.
- Dry-run and signal-only modes must not load secrets.

## File Changes

| Path | Action |
|---|---|
| `pybuy/manage_secrets.py` | New file. Encrypt/decrypt CLI. |
| `pybuy/secrets.env.enc` | New encrypted credential store. Local only. |
| `pybuy/place_order.py` | Modify. Load credentials from environment or encrypted secrets file. Remove default `.env` fallback. |
| `pybuy/trade_history.py` | Modify. Use `manage_secrets.py` flow or environment variables. |
| `pybuy/requirements.txt` | Modify. Add `cryptography`. |
| `pybuy/.env.example` | Keep. Placeholders only. |
| `pybuy/.env` | Delete after migration. Do not commit. |
| `pybuy/README.md` | Update. Document new setup flow. |
| `lib/vathbot/secrets.ex` | New file. Decrypt encrypted secrets and hold them in a GenServer. |
| `lib/vathbot/application.ex` | Modify. Prompt for unlock when live trading is enabled. |
| `lib/vathbot/trade_executor.ex` | Modify. Pass credentials through subprocess environment. |
| `config/config.exs` | Modify. Add `secrets_file` path config. |
| `.gitignore` | Modify. Ignore plaintext and encrypted secrets. |
| `README.md` | Update. Document live trading setup. |
| `test/vathbot/trade_integration_test.exs` | Modify. Must be run manually and require password input

## Encrypted File Format

Use a simple, auditable file format implemented in Python with the `cryptography` library and mirrored in Elixir with `:crypto`.

### On-Disk Layout

```text
vathbot-secrets-v1
<salt: 16 bytes raw, base64-encoded line>
<nonce: 12 bytes raw, base64-encoded line>
<ciphertext+tag: base64-encoded line>
```

### Crypto Parameters

| Parameter | Value |
|---|---|
| KDF | PBKDF2-HMAC-SHA256 |
| Iterations | `600_000` |
| Key length | 32 bytes |
| Cipher | AES-256-GCM |
| Salt | 16 random bytes per file |
| Nonce | 12 random bytes per encryption |

### Plaintext Body

The decrypted plaintext body is standard `.env` format:

```env
POLYMARKET_PRIVATE_KEY=...
POLYMARKET_FUNDER=0x...
POLYMARKET_SIGNATURE_TYPE=2
```

## Python CLI: `pybuy/manage_secrets.py`

Create a new CLI for encrypting, decrypting, and verifying the secrets file.

### Commands

```bash
python pybuy/manage_secrets.py encrypt INPUT.env OUTPUT.enc
python pybuy/manage_secrets.py decrypt INPUT.enc
python pybuy/manage_secrets.py verify INPUT.enc
```

`verify` is optional but recommended.

### Requirements

- Use `getpass.getpass()` for password entry.
- Confirm password twice on encryption.
- Exit with `0` on success and nonzero on failure.
- Never log passwords.
- Never log decrypted credential values.
- Document crypto constants in the module docstring.
- Constants must match the Elixir implementation exactly.

## Python: `pybuy/place_order.py`

Modify `place_order.py` as follows:

1. Prefer credentials already present in `os.environ`.
2. Support standalone CLI usage with:

   ```bash
   python pybuy/place_order.py --secrets-file pybuy/secrets.env.enc
   ```

3. When `--secrets-file` is provided, prompt for the password with hidden input.
4. Do not default to `pybuy/.env`.
5. Remove plaintext `--env-file`, or require an explicit unsafe flag such as:

   ```bash
   --allow-plaintext
   ```

6. Never accept secrets as command-line arguments.
7. Never print credentials or decrypted env contents.

## Python: `pybuy/trade_history.py`

Modify `trade_history.py` so that it no longer calls:

```python
load_credentials(DEFAULT_ENV_FILE)
```

at import time.

Use one of these instead:

- Credentials from environment variables.
- Explicit `--secrets-file` unlock flow.
- No credentials at all for read-only or dry-run flows that do not need them.

## Elixir: `Vathbot.Secrets`

Create:

```text
lib/vathbot/secrets.ex
```

The module should expose:

```elixir
unlock(password)
locked?()
credentials()
decrypt_file(path, password)
```

### Responsibilities

- Run as a GenServer.
- Hold decrypted credentials in memory only.
- Expose a pure `decrypt_file/2` function for tests.
- Parse decrypted `.env` text into a key/value map.
- Refuse access when locked.
- Never write decrypted secrets to disk.
- Never log decrypted secrets.

### Expected API Behavior

```elixir
Vathbot.Secrets.locked?()
# => true | false

Vathbot.Secrets.unlock(password)
# => :ok | {:error, reason}

Vathbot.Secrets.credentials()
# => {:ok, map} | {:error, :locked}
```

## Elixir Startup Behavior

When live trading is enabled:

```elixir
config :vathbot,
  execute_trades: System.get_env("VATHBOT_EXECUTE_TRADES") in ["1", "true"],
  secrets_file: System.get_env("VATHBOT_SECRETS_FILE", "pybuy/secrets.env.enc")
```

At application startup:

```elixir
if execute_trades do
  password = IO.getpass("Live trading password: ")

  case Vathbot.Secrets.unlock(password) do
    :ok ->
      :ok

    {:error, reason} ->
      raise "Failed to unlock live trading secrets: #{inspect(reason)}"
  end
end
```

Required behavior:

- Prompt once per `mix run` session.
- Prompt only when `VATHBOT_EXECUTE_TRADES=1` or equivalent.
- Wrong password exits with an error.
- Dry-run mode never prompts.

## Elixir: `TradeExecutor`

Modify `lib/vathbot/trade_executor.ex` so that it passes credentials to Python through subprocess environment variables.

Do this:

```elixir
System.cmd("python3", ["pybuy/place_order.py"],
  env: merged_env
)
```

Do not do this:

```elixir
System.cmd("python3", ["pybuy/place_order.py", private_key])
```

### Credential Passing Rules

- Pass credentials as subprocess environment variables.
- Do not pass credentials as CLI arguments.
- Pass only the variables needed by `place_order.py`.
- Do not log the merged environment.
- Do not log the order payload if it contains sensitive data.

## `.gitignore`

Add:

```gitignore
pybuy/.env
pybuy/secrets.env
pybuy/secrets.env.enc
```

The encrypted file should not be committed by default.

## User-Facing Migration Flow

Document this flow in `README.md` and `pybuy/README.md`:

```bash
cp pybuy/.env.example pybuy/secrets.env
# Fill pybuy/secrets.env with credentials from a new dev or bot wallet.

python pybuy/manage_secrets.py encrypt pybuy/secrets.env pybuy/secrets.env.enc

rm -f pybuy/secrets.env pybuy/.env

VATHBOT_EXECUTE_TRADES=1 mix run --no-halt
```

## Integration Tests

Update:

```text
test/vathbot/trade_integration_test.exs
```

### Requirements

- Require user to run with relevant cli command. Prompt for password to initiate actual test.
- Never read `pybuy/.env`.
- Verify wrong password fails closed.
- Verify dry-run mode does not require password.
- Verify Python encrypt output can be decrypted by Elixir.
- Verify Elixir decrypt output matches expected fixture contents.

## Implementation Order

Implement in this order:

1. `pybuy/manage_secrets.py`
2. Python encrypt/decrypt round-trip test
3. `Vathbot.Secrets.decrypt_file/2`
4. Cross-language Python encrypt → Elixir decrypt fixture test
5. `Vathbot.Secrets` GenServer
6. `pybuy/place_order.py` changes
7. `pybuy/trade_history.py` changes
8. `lib/vathbot/application.ex` startup unlock flow
9. `lib/vathbot/trade_executor.ex` subprocess environment wiring
10. `.gitignore` updates
11. `pybuy/README.md` updates
12. top-level `README.md` updates
13. integration test updates

## Acceptance Criteria

- [ ] `pybuy/.env` is not read by default anywhere at runtime.
- [ ] Python can encrypt a secrets file.
- [ ] Python can decrypt its own encrypted secrets file.
- [ ] Elixir can decrypt a Python-created encrypted secrets file.
- [ ] Python encrypt and Elixir decrypt are compatible.
- [ ] Password prompt appears only when `VATHBOT_EXECUTE_TRADES=1` or equivalent.
- [ ] Wrong password prevents live orders.
- [ ] Dry-run mode does not prompt for password.
- [ ] Signal-only mode does not prompt for password.
- [ ] Integration tests support `VATHBOT_INTEGRATION_PASSWORD`.
- [ ] No decrypted secrets are written to disk.
- [ ] No secrets are passed as CLI arguments.
- [ ] No secrets are logged.
- [ ] `.gitignore` excludes plaintext and encrypted local secrets.

## Defaults

| Question | Default |
|---|---|
| Prompt frequency | Once per `mix run` session |
| Encrypted file path | `pybuy/secrets.env.enc` |
| Wrong password behavior | Exit with error |
| Commit `.enc` file? | No |
| Runtime plaintext `.env` fallback? | No |

## Files to Read First

The implementing agent should inspect these files before making changes:

```text
lib/vathbot/trade_executor.ex
lib/vathbot/order_handler.ex
lib/vathbot/application.ex
config/config.exs
pybuy/place_order.py
pybuy/trade_history.py
test/vathbot/trade_integration_test.exs
```

## Out of Scope

Do not modify these areas as part of this task:

- `polybot2/`
- `polymarket/`
- Hardware wallet integration
- Remote signing
- CI secret injection beyond `VATHBOT_INTEGRATION_PASSWORD`

## Notes for the Agent

Treat this as a security-sensitive change.

Prefer small, testable commits. Avoid broad refactors. Preserve dry-run behavior. Fail closed for anything related to live trading. Never print, log, or persist decrypted credentials.
