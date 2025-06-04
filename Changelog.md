# Changelog

## v0.2.1 - Patch

_Released unreleased_

- If `:clean_start` option is `true`, truncate the buffer log file and skip replay when the producer starts.

## v0.2.0 - Patch

_Released 2025-06-03_

- Add support for wrapping the ETS buffer cache with [:disk_log](https://www.erlang.org/docs/17/man/disk_log) to persist cached messages for producer.
  - Introduced new option `buffer_durability` which can be either `:durable` or `:transient`. When `:durable`, 
    messages will be persisted to disk to ensure messages are not lost if the producer crashes. Defaults to
    `:transient` (in-memory buffer only).
  - New option `buffer_log_dir` can be either a string, or a zero-arity function that returns the directory to
    store buffer logs.
  - Added new telemetry events for `:durable` buffer operations.

## v0.1.1 - Patch

_Released unreleased_

- Emitting `off_broadway_emqtt.receive_message.ack` reads message topic from message receipt instead of from the message body.
 This ensures that topic is included in telemetry events even if the message has been altered during dispatch.
- Move `emqtt.start_link/1` and `emqtt.connect/1` to a `handle_continue/2` callback to prevent blocking `GenServer.init/1`.
- Convert `host` and `server_name_indication` to charlist when validating options.
- Return new state from `handle_continue` on connection error.
- Publish the `payload` field as message data, and the rest as metadata.

## v0.1.0 - Initial release

_Released 2024-09-24_

The initial release supports connecting to an MQTT broker using  [emqtt](https://github.com/emqx/emqtt), 
and consume messages using a Broadway pipeline.

**Supported features**
- [x] Support most  `emqtt` configurable options as producer config options.
- [x] Specify buffer size and overflow strategy for the `ets` table buffer.
- [x] `OffBroadway.EMQTT.MessageHandler` behaviour to support overriding default implementation.
- [x] Telemetry events for observability.
