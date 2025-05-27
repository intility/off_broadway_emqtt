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
        ],
        buffer_size: 1000,
        buffer_overflow_strategy: :reject,
        buffer_durability: :durable
      ]

      assert {:ok, _} = NimbleOptions.validate(opts, Options.definition())
    end

    test "topic validations succeeds" do
      opts = [
        topics: [
          {"commands/topic", 0},
          {"commands/topic", 1},
          {"commands/topic", 2},
          {"commands/topic", :qos0},
          {"commands/topic", :qos1},
          {"commands/topic", :qos2},
          {"commands/topic", :at_most_once},
          {"commands/topic", :at_least_once},
          {"commands/topic", :exactly_once},
          {"commands/topic", {:rh, 0}},
          {"commands/topic", {:rh, 1}},
          {"commands/topic", {:rh, 2}},
          {"commands/topic", {:rap, true}},
          {"commands/topic", {:nl, true}}
        ],
        config: [host: "test.mosquitto.org"]
      ]

      assert {:ok, _} = NimbleOptions.validate(opts, Options.definition())
    end

    test ":emqtt basic authentication" do
      opts = [
        config: [
          host: "test.mosquitto.org",
          port: 1883,
          username: "rw",
          password: "readwrite"
        ]
      ]

      assert {:ok, _} = NimbleOptions.validate(opts, Options.definition())
    end

    test ":emqtt validation fails when host is missing" do
      opts = [
        config: [
          port: 1883,
          username: "rw",
          password: "readwrite"
        ]
      ]

      assert {:error, %{message: message}} = NimbleOptions.validate(opts, Options.definition())
      assert message =~ "required :host option not found"
    end
  end
end
