import Config

config :vathbot, :data_root, "data"
config :vathbot, :start_runtime, true

pybuy_dir = Path.expand("../pybuy", __DIR__)
venv_python = Path.join(pybuy_dir, "venv/bin/python")

config :vathbot, :pybuy_dir, pybuy_dir

config :vathbot, :pybuy_python,
         System.get_env("VATHBOT_PYTHON") ||
           if(File.exists?(venv_python), do: venv_python, else: "python3")

import_config "#{config_env()}.exs"
