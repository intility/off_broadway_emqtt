# OffBroadway.EMQTT

![pipeline status](https://github.com/Intility/off_broadway_emqtt/actions/workflows/elixir.yaml/badge.svg?event=push&branch=main)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg?style=plastic)](https://hexdocs.pm/off_broadway_emqtt/readme.html)

An MQTT connector based on [emqtt](https://github.com/emqx/emqtt) for [Broadway](https://github.com/dashbitco/broadway).

MQTT (Message Queuing Telemetry Transport) is a lightweight messaging protocol designed for small sensors and mobile devices 
with limited bandwidth. MQTT is commonly used in IoT (Internet of Things), home and industrial automation, healthcare and energy management
amongst others.

Several well-known systems and cloud providers provides MQTT broker services that can be used to build automation systems. These includes
Amazon Web Services (AWS IoT), Microsoft Azure (IoT Hub, Event Grid), IBM Watson IoT Platform and Eclipse Mosquitto.

## Usage

``` elixir
defmodule MyBroadway do 
  use Broadway
  alias Broadway.Message
  
  def start_link(_opts) do 
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {OffBroadway.EMQTT.Producer, 
           topics: [
             {"test/topic1", :at_most_once},  # QoS 0
             {"test/topic2", :at_least_once}, # QoS 1
             {"test/topic3", :exactly_once}   # QoS 2
           ],
           config: [
             host: "test.mosquitto.org",
             port: 1884,
             username: "rw",
             password: "readwrite"
           ]
        },
        concurrency: 5
      ],
      processors: [
        default: [concurrency: 10]
      ],
      batchers: [
        default: [
          batch_size: 200,
          concurrency: 5 
        ]
      ]
    )
  end
  
  @impl true
  def handle_message(_, %Message{} = message, _) do 
    IO.inspect(message, label: "Handled message from producer")
  end
  
  @impl true
  def handle_batch(_, messages, _, _) do 
    IO.inspect("Received a batch of #{length(messages)} messages", label: "Handled batch from producer")
    messages
  end
end
```


## Installation

This package is [available in Hex](https://hex.pm/packages/off_broadway_emqtt), and can be installed
by adding `off_broadway_emqtt` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:off_broadway_emqtt, "~> 0.1.0"},
    {:cowlib, "~> 2.12", override: true}  # Required for `:emqtt` dependency resolution
  ]
end
```

By default, `:emqtt` compiles the `Quic` library. It is possible to build without by setting the environment variable
`BUILD_WITHOUT_QUIC=1`.

``` shell
BUILD_WITHOUT_QUIC=1 mix deps.compile
```

