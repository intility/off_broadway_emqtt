# Changelog

## [0.3.0](https://github.com/intility/off_broadway_emqtt/compare/v0.2.1...v0.3.0) (2026-04-17)

_Breaking changes and reliability rework._

This release removes the ETS/disk-log buffer layer and replaces it with proper
MQTT protocol-level backpressure. The result is a simpler, more reliable producer
that correctly participates in QoS 1/2 guarantees.

### Breaking changes

- **ETS buffer removed.** The options `buffer_size`, `buffer_overflow_strategy`,
  `buffer_durability`, and `buffer_log_dir` no longer exist. Remove them from
  your configuration. Backpressure is now handled entirely by `max_inflight` and
  the MQTT protocol.
- **`clean_start` defaults to `false`** (was `true`). With the old default, the
  broker discarded the session on every reconnect, silently losing all unACKed
  QoS 1/2 messages. The new default preserves the session so the broker redelivers
  unACKed messages after a producer restart. If you explicitly want a fresh session
  on each connect, set `config: [clean_start: true]`.
- **`topics` is now required.** Previously it defaulted to `[]`, starting a
  producer that subscribed to nothing. Omitting `topics` now raises at startup.
- **`MessageHandler` behaviour simplified.** The callbacks `handle_connect/1`,
  `handle_disconnect/1`, and `handle_pubrel/1` have been removed. Only
  `handle_message/3` remains. Custom handlers implementing the removed callbacks
  must delete them.
- **`concurrency > 1` requires `shared_group`.** Starting a pipeline with multiple
  producer instances and no `shared_group` now raises at startup. Without shared
  subscriptions every producer receives every message, causing duplicates.
- **Client ID suffix `_N` is now always appended.** Each producer instance connects
  with `{clientid}_0`, `{clientid}_1`, etc. A pipeline that previously connected as
  `my-client` now connects as `my-client_0`. If you have a persistent broker session
  keyed by the exact client ID, update the `clientid` in your config to match the new
  suffix (e.g. `clientid: "my-client_0"`) or accept that the session will be treated
  as new on first connect.
- **emqtt bumped to `~> 1.14`**, cowlib to `~> 2.13.0`.

### Bug fixes

- **QoS 2 acknowledgement fixed.** The `pubcomp` step was incorrectly calling
  `:emqtt.pubrec` instead of `:emqtt.pubcomp`, breaking the QoS 2 handshake
  entirely. QoS 2 exactly-once delivery now works correctly.

### New features

- **Protocol-level backpressure via `max_inflight`.** The broker stops delivering
  new messages once `max_inflight` unACKed QoS 1/2 messages are outstanding.
  Default is 100. For MQTT v5, `Receive-Maximum` is automatically set in the
  CONNECT properties so the broker enforces the limit server-side.
- **`shared_group` option** for distributing messages across multiple producer
  instances using MQTT shared subscriptions (`$share/{group}/{topic}`).
- **New `config` options:** `reconnect`, `reconnect_timeout`, `low_mem`.
- **`connection: :down` telemetry event** emitted when the MQTT connection is lost,
  with `%{client_id: string, producer_index: integer, reason: term}` metadata.
- **Clearer startup errors.** A `Logger.error` message including host and port is
  emitted when the producer fails to connect to the broker.
- **`persistent_term` cleanup.** The ack-options entry written at pipeline startup
  is now erased when the pipeline stops, preventing accumulation in long-running
  applications that start and stop pipelines dynamically.

### Migration from v0.2.x

#### Remove buffer options

The ETS/disk-log buffer has been removed. Delete these options from your producer config:

```elixir
# Remove all of these:
buffer_size: 10_000,
buffer_overflow_strategy: :drop_head,
buffer_durability: :durable,
buffer_log_dir: System.tmp_dir!(),
```

Backpressure is now handled by `max_inflight`.

#### Review clean_start

`clean_start` now defaults to `false` (was `true`). This is the safer default: the broker
redelivers unACKed QoS 1/2 messages after a restart instead of discarding them.

If your pipeline was relying on the broker discarding the session on reconnect, add
`config: [clean_start: true]` explicitly. Be aware this means unACKed messages are lost
on every restart.

#### Remove MessageHandler callbacks

If you implemented a custom `MessageHandler`, delete any `handle_connect/1`, `handle_disconnect/1`,
or `handle_pubrel/1` callbacks. Only `handle_message/3` is part of the behaviour.

#### Add shared_group for concurrency > 1

If you were running with `concurrency > 1`, you must now add `shared_group`:

```elixir
# Before (would cause duplicate messages):
producer: [
  module: {OffBroadway.EMQTT.Producer, topics: [{"my/topic", 1}], config: [...]},
  concurrency: 3
]

# After:
producer: [
  module: {OffBroadway.EMQTT.Producer,
    topics: [{"my/topic", 1}],
    shared_group: "my-pipeline",
    config: [...]
  },
  concurrency: 3
]
```

#### Update dependencies

```elixir
{:off_broadway_emqtt, "~> 0.3.0"}
```

---

## [0.2.1](https://github.com/intility/off_broadway_emqtt/compare/v0.2.0...v0.2.1) (2025-06-05)

- If `:clean_start` option is `true`, truncate the buffer log file and skip replay when the producer starts.
- Properly disconnect from the MQTT broker on terminate.

## [0.2.0](https://github.com/intility/off_broadway_emqtt/compare/v0.1.0...v0.2.0) (2025-06-03)

- Add support for wrapping the ETS buffer cache with [:disk_log](https://www.erlang.org/docs/17/man/disk_log) to persist cached messages for producer.
  - Introduced new option `buffer_durability` which can be either `:durable` or `:transient`. When `:durable`, 
    messages will be persisted to disk to ensure messages are not lost if the producer crashes. Defaults to
    `:transient` (in-memory buffer only).
  - New option `buffer_log_dir` can be either a string, or a zero-arity function that returns the directory to
    store buffer logs.
  - Added new telemetry events for `:durable` buffer operations.

## 0.1.1 (unreleased)

_Never tagged. Changes rolled into later releases._

- Emitting `off_broadway_emqtt.receive_message.ack` reads message topic from message receipt instead of from the message body.
 This ensures that topic is included in telemetry events even if the message has been altered during dispatch.
- Move `emqtt.start_link/1` and `emqtt.connect/1` to a `handle_continue/2` callback to prevent blocking `GenServer.init/1`.
- Convert `host` and `server_name_indication` to charlist when validating options.
- Return new state from `handle_continue` on connection error.
- Publish the `payload` field as message data, and the rest as metadata.

## 0.1.0 (2024-09-24)

_Initial release._

The initial release supports connecting to an MQTT broker using  [emqtt](https://github.com/emqx/emqtt), 
and consume messages using a Broadway pipeline.

**Supported features**
- [x] Support most  `emqtt` configurable options as producer config options.
- [x] Specify buffer size and overflow strategy for the `ets` table buffer.
- [x] `OffBroadway.EMQTT.MessageHandler` behaviour to support overriding default implementation.
- [x] Telemetry events for observability.
