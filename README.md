# OffBroadway.EMQTT

![pipeline status](https://github.com/Intility/off_broadway_emqtt/actions/workflows/elixir.yaml/badge.svg?event=push&branch=main)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg?style=plastic)](https://hexdocs.pm/off_broadway_emqtt/readme.html)

An MQTT connector based on [emqtt](https://github.com/emqx/emqtt) for [Broadway](https://github.com/dashbitco/broadway).

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
           buffer_size: 10_000,
           buffer_overflow_strategy: :drop_head,
           topics: [
             {"test/topic1", :exactly_once},
             {"test/topic2", :at_most_once},
             {"test/topic3", :at_least_once},
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
    {:off_broadway_emqtt, "~> 0.1.0"}
  ]
end
```

By default, `:emqtt` compiles the `Quic` library. It is possible to build without by setting the environment variable
`BUILD_WITHOUT_QUIC=1`.

``` shell
BUILD_WITHOUT_QUIC=1 mix deps.compile
```

