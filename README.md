# OffBroadway.EMQTT

![Elixir CI](https://github.com/Intility/off_broadway_emqtt/actions/workflows/elixir.yaml/badge.svg?event=push&branch=main)
[![License: Apache 2.0 ](https://img.shields.io/badge/License-Apache2-yellow.svg)](https://opensource.org/license/apache-2-0)
[![Hex version badge](https://img.shields.io/hexpm/v/off_broadway_emqtt.svg)](https://hex.pm/packages/off_broadway_emqtt)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/off_broadway_emqtt/readme.html)

An MQTT connector based on [emqtt](https://github.com/emqx/emqtt) for [Broadway](https://github.com/dashbitco/broadway).

MQTT is a lightweight publish/subscribe protocol widely used in IoT, industrial automation, and telemetry.
This library connects a Broadway pipeline to an MQTT broker, using the MQTT protocol itself for
backpressure and message reliability rather than an in-process buffer.

## Installation

```elixir
def deps do
  [
    {:off_broadway_emqtt, "~> 0.3.0"}
  ]
end
```

By default, `:emqtt` compiles the Quic transport library. To build without it:

```shell
BUILD_WITHOUT_QUIC=1 mix deps.compile
```

## Usage

```elixir
defmodule MyBroadway do
  use Broadway

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {OffBroadway.EMQTT.Producer,
          topics: [
            {"sensors/status",      :at_most_once},    # QoS 0
            {"sensors/temperature", :at_least_once},   # QoS 1
            {"sensors/humidity",    :exactly_once}     # QoS 2
          ],
          max_inflight: 100,
          config: [
            host: "mqtt.example.com",
            port: 1883,
            username: "my-user",
            password: "my-password",
            clientid: "my-pipeline"
          ]
        },
        concurrency: 1
      ],
      processors: [default: [concurrency: 10]],
      batchers: [default: [batch_size: 100, batch_timeout: 500, concurrency: 5]]
    )
  end

  @impl true
  def handle_message(_, message, _context) do
    IO.inspect(message.data, label: "payload")
    IO.inspect(message.metadata.topic, label: "topic")
    message
  end

  @impl true
  def handle_batch(_, messages, _, _) do
    messages
  end
end
```

Each MQTT message is delivered as a Broadway message where `data` is the raw payload binary
and `metadata` contains the remaining fields from the MQTT packet (`topic`, `qos`, `packet_id`, etc.).

## Reliability and message delivery

### QoS levels

Use QoS 1 (`:at_least_once`) or QoS 2 (`:exactly_once`) for reliable delivery. Messages are only
acknowledged to the broker after Broadway successfully processes them. If Broadway fails to process
a message, the broker redelivers it (with QoS 1/2).

QoS 0 (`:at_most_once`) provides no delivery guarantee. The broker fires and forgets.

### Backpressure via max_inflight

The `max_inflight` option limits how many unACKed QoS 1/2 messages the broker will send before
waiting for acknowledgements. This is the primary backpressure mechanism: the broker stops
delivering new messages once the window is full.

For MQTT v5 (`config: [proto_ver: :v5]`), `Receive-Maximum` is set automatically in the CONNECT
properties so the broker enforces the limit server-side.

### Session persistence across restarts

`clean_start` defaults to `false`. When a producer restarts (after a crash or deployment), the
broker recognises the `clientid` and redelivers any QoS 1/2 messages that were not acknowledged
before the restart. No messages are lost between restarts.

If you want a fresh session on every connect (discarding unACKed messages), set
`config: [clean_start: true]` explicitly.

> [!NOTE]
> Each producer instance connects with the configured `clientid` plus an
> index suffix: `my-pipeline_0`, `my-pipeline_1`, and so on. A `concurrency: 1` pipeline configured
> with `clientid: "my-pipeline"` appears on the broker as `my-pipeline_0`. If you are upgrading
> from v0.2.x and rely on an exact clientid for a persistent session or ACL, either change your
> config to `clientid: "my-pipeline_0"` or accept that the session will be treated as new on the
> first v0.3.0 connect.

### Reconnection

By default, if the MQTT connection is lost the producer process stops and Broadway's supervisor
restarts it. The fresh producer creates a new emqtt connection and re-subscribes to all topics.
With `clean_start: false` (the default), the broker redelivers any unACKed QoS 1/2 messages.

Alternatively, you can enable emqtt's built-in reconnect by passing `reconnect` in `config`:

```elixir
config: [
  host: "mqtt.example.com",
  clientid: "my-pipeline",
  reconnect: :infinity,
  reconnect_timeout: 5,
  clean_start: false
]
```

> [!IMPORTANT] 
> emqtt's reconnect reopens the TCP connection but does **not** re-subscribe. You must
> set `clean_start: false` so the broker restores the session and delivers messages again. If you
> enable `reconnect` with `clean_start: true`, messages silently stop arriving after the first reconnect.

### on_success and on_failure

| Option       | Value             | Behaviour                                                  |
|--------------|-------------------|------------------------------------------------------------|
| `on_success` | `:ack` (default)  | ACKs the message to the broker after successful processing |
| `on_success` | `:noop`           | Does not ACK; broker will redeliver                        |
| `on_failure` | `:noop` (default) | Does not ACK; broker will redeliver (QoS 1/2)              |
| `on_failure` | `:ack`            | ACKs even on failure; message is not redelivered           |

## Multiple consumers (concurrency)

To distribute messages across multiple producer instances, set `concurrency > 1` and provide a
`shared_group` name. Without `shared_group`, every producer instance receives every message,
causing duplicates.

```elixir
producer: [
  module: {OffBroadway.EMQTT.Producer,
    topics: [{"work/queue", :at_least_once}],
    shared_group: "my-pipeline",
    config: [host: "mqtt.example.com", clientid: "worker"]
  },
  concurrency: 3
]
```

This creates three MQTT connections (`worker_0`, `worker_1`, `worker_2`) all in the shared group
`my-pipeline`. The broker distributes messages across them using MQTT shared subscriptions
(`$share/my-pipeline/work/queue`).

`max_inflight` applies per connection. With `concurrency: 3` and `max_inflight: 100`, up to 300
unACKed messages can be in-flight across the pipeline at once.

## Custom message handler

Implement `OffBroadway.EMQTT.MessageHandler` to customise how MQTT messages are converted to
Broadway messages. The default handler places the raw payload binary in `data` and the rest of
the MQTT packet fields in `metadata`.

```elixir
defmodule MyApp.JsonHandler do
  @behaviour OffBroadway.EMQTT.MessageHandler

  @impl true
  def handle_message(message, ack_ref, _opts) do
    {payload, metadata} = Map.pop(message, :payload)

    %Broadway.Message{
      data: Jason.decode!(payload),
      metadata: metadata,
      acknowledger: {OffBroadway.EMQTT.Acknowledger, ack_ref, %{}}
    }
  end
end
```

```elixir
producer: [
  module: {OffBroadway.EMQTT.Producer,
    topics: [{"events/#", :at_least_once}],
    message_handler: MyApp.JsonHandler,
    config: [host: "mqtt.example.com"]
  },
  concurrency: 1
]
```

## Telemetry

| Event                                             | Measurements                 | Metadata                                                                                  |
|---------------------------------------------------|------------------------------|-------------------------------------------------------------------------------------------|
| `[:off_broadway_emqtt, :producer, :init]`         | `%{time: integer}`           | `%{broadway_name: term, producer_index: integer}`                                         |
| `[:off_broadway_emqtt, :producer, :terminate]`    | `%{time: integer}`           | `%{broadway_name: term, producer_index: integer, client_id: string \| nil, reason: term}` |
| `[:off_broadway_emqtt, :connection, :up]`         | `%{time: integer}`           | `%{client_id: string, producer_index: integer}`                                           |
| `[:off_broadway_emqtt, :connection, :down]`       | `%{time: integer}`           | `%{client_id: string, producer_index: integer, reason: term}`                             |
| `[:off_broadway_emqtt, :subscription, :success]`  | `%{time: integer}`           | `%{client_id: string, producer_index: integer, topic: string, granted_qos: 0..2}`         |
| `[:off_broadway_emqtt, :subscription, :error]`    | `%{time: integer}`           | `%{client_id: string, producer_index: integer, topic: string, reason: term}`              |
| `[:off_broadway_emqtt, :receive_message, :start]` | `%{time: integer, count: 1}` | `%{client_id: string, producer_index: integer, topic: string, qos: integer}`              |
| `[:off_broadway_emqtt, :receive_message, :ack]`   | `%{time: integer, count: 1}` | `%{topic: string, qos: integer, status: :on_success \| :on_failure}`                      |

See the Producer moduledoc for common `connection.down` reason shapes (auth failures, TLS errors, transport errors).

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for upgrade instructions and release history.
