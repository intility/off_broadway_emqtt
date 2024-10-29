# Changelog

## v0.1.1 - Patch

_Released unreleased_

- Emitting `off_broadway_emqtt.receive_message.ack` reads message topic from message receipt instead of from the message body.
 This ensures that topic is included in telemetry events even if the message has been altered during dispatch.
- Move `emqtt.start_link/1` and `emqtt.connect/1` to a `handle_continue/2` callback to prevent blocking `GenServer.init/1`.
- Convert `host` and `server_name_indication` to charlist when validating options.

## v0.1.0 - Initial release

_Released 2024-09-24_

The initial release supports connecting to an MQTT broker using  [emqtt](https://github.com/emqx/emqtt), 
and consume messages using a Broadway pipeline.

**Supported features**
- [x] Support most  `emqtt` configurable options as producer config options.
- [x] Specify buffer size and overflow strategy for the `ets` table buffer.
- [x] `OffBroadway.EMQTT.MessageHandler` behaviour to support overriding default implementation.
- [x] Telemetry events for observability.
