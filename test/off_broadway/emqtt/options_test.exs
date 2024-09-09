defmodule OffBroadway.EMQTT.OptionsTest do
  use ExUnit.Case
  alias OffBroadway.EMQTT.Options

  describe "parse" do
    test "full config options" do
      opts = [
        config: [
          host: "test.mosquitto.org",
          port: 1883,
          username: "rw",
          password: "readwrite",
          ssl: true,
          ssl_opts: [
            cacertfile: "mosquitto.org.crt",
            server_name_indication: "test.mosquitto.org",
            verify: :verify_peer,
            certfile: "client.crt",
            keyfile: "client.key"
          ]
        ]
      ]

      assert {:ok, ^opts} = NimbleOptions.validate(opts, Options.definition())
    end
  end
end
