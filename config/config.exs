import Config

case config_env() do
  :dev ->
    config :logger, level: :info

  :test ->
    config :logger, level: :info

  _ ->
    :ok
end
