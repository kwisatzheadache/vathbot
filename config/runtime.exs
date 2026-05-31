import Config

# Runtime config — read env vars when the app starts (mix run, releases).
# config/config.exs is also evaluated at compile time; this file is the source
# of truth for VATHBOT_* flags at startup.

if config_env() != :test do
  config :vathbot, :execute_trades,
         System.get_env("VATHBOT_EXECUTE_TRADES") in ["1", "true"]

  config :vathbot, :secrets_file,
         System.get_env("VATHBOT_SECRETS_FILE", "pybuy/secrets.env.enc")
end
