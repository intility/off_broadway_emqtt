# Changelog

## [0.4.0](https://github.com/intility/off_broadway_emqtt/compare/v0.3.0...v0.4.0) (2026-04-17)


### Features

* Add .tool-versions file with Erlang and Elixir versions ([298aaa3](https://github.com/intility/off_broadway_emqtt/commit/298aaa3e25bd7a11999bc7239254e9ed6f1d5195))
* Add comprehensive telemetry events for producer lifecycle and subscriptions ([c9812b0](https://github.com/intility/off_broadway_emqtt/commit/c9812b0102dded55047cac28c2fd34585f29a59d))
* Add disk log support for ETS buffer cache ([a4196b9](https://github.com/intility/off_broadway_emqtt/commit/a4196b9d4121c9e748fd2ee910eece473c55adea))
* add MQTT v5 Receive-Maximum flow control and comprehensive tests ([5b58567](https://github.com/intility/off_broadway_emqtt/commit/5b5856715407f14f904a6efd827da779e1758272))
* **broker:** add durable buffer storage with disk_log ([8c5c7fe](https://github.com/intility/off_broadway_emqtt/commit/8c5c7fe0a725544b4cf96901963fdfef2472897d))
* **broker:** Add telemetry spans for buffer operations ([a53cf30](https://github.com/intility/off_broadway_emqtt/commit/a53cf300db817e14b6fd1b551ea18fc35509c512))
* **broker:** If clean_start option is true, skip buffer replay ([89c357b](https://github.com/intility/off_broadway_emqtt/commit/89c357bbfa9750e4c8fb2ad2e16f7303189391ed))
* **buffer:** updated docs ([f888f67](https://github.com/intility/off_broadway_emqtt/commit/f888f676ee87758a2a7cb6ffc2024ce878dc4ae5))
* **ci:** update Elixir/OTP versions and enhance Mosquitto setup ([115dbcc](https://github.com/intility/off_broadway_emqtt/commit/115dbccb82ce8620c7db7f63a45287a2248fadac))
* **deps:** update dependencies to latest versions ([c1337ba](https://github.com/intility/off_broadway_emqtt/commit/c1337ba3ece7ba4c351dbcb5b3f2a734b63b33b4))
* **emqtt:** Improve broker termination process ([cf791ee](https://github.com/intility/off_broadway_emqtt/commit/cf791ee2dd637247643bcbdf05e5179a3849689d))
* **mosquitto:** Add TLS certificate generation and configuration ([9bda044](https://github.com/intility/off_broadway_emqtt/commit/9bda044b0f2a7730a4651cb2068ac5d450d61b65))
* Properly disconnect from MQTT broker on terminate ([b63dcd4](https://github.com/intility/off_broadway_emqtt/commit/b63dcd42e25816aaaa8d04b47eb8710260863a3e))
* **telemetry:** Add detailed telemetry documentation ([23ea346](https://github.com/intility/off_broadway_emqtt/commit/23ea3467f81743f48f2d2811bc9d6906c238343a))


### Bug Fixes

* **broker:** handle subscription errors and adjust logging level for buffer threshold ([38cbb7f](https://github.com/intility/off_broadway_emqtt/commit/38cbb7fc75d5f2da00969e13750e1596635ec884))
* check for reference before demonitor ([cc3c92d](https://github.com/intility/off_broadway_emqtt/commit/cc3c92db4fc491ac458231004c960420e2813792))
* Clean up persistent_term and improve error logging ([5667f83](https://github.com/intility/off_broadway_emqtt/commit/5667f83d02ba035b9ebc25b7a47a35b57a7802fe))
* **connection:** call :emqtt.pubcomp instead of :emqtt.pubrec for QoS 2 ([2013327](https://github.com/intility/off_broadway_emqtt/commit/201332717e44d3aa54feb6d208c309e4fd136d99))
* cowlib dep version ([48bf32e](https://github.com/intility/off_broadway_emqtt/commit/48bf32ecbf33058afaff1f53ca8ce9e14495ba1c))
* **deps:** Make cowlib optional dev dependency ([162ce26](https://github.com/intility/off_broadway_emqtt/commit/162ce26a53cb0ea4d5f15eae79bf0b8dc785dcec))
* don't block GenServer.init/1 ([850a370](https://github.com/intility/off_broadway_emqtt/commit/850a37081b5dfd83186e085c4759c49668c3f07c))
* needs to have override true to run tests ([d9934eb](https://github.com/intility/off_broadway_emqtt/commit/d9934eb0760843c40f26903b718c1e5282dd19d3))
* **options:** safe defaults for clean_start and topics ([ca092f7](https://github.com/intility/off_broadway_emqtt/commit/ca092f7f250f9fcd8ca4e5c74cb7d59928babaa7))
* path ([520ea36](https://github.com/intility/off_broadway_emqtt/commit/520ea367b2d139522903940e1f6a57290dd102ba))
* **producer:** Handle MQTT disconnection events and improve error handling ([1ba355e](https://github.com/intility/off_broadway_emqtt/commit/1ba355e15be1b4b014aa61d5bf898c6f5b765e9f))
* read topic from message receipt ([ebce1f0](https://github.com/intility/off_broadway_emqtt/commit/ebce1f049e9385ed5596f1f89da7525b21d94b88))
* remove override: true ([7ed52ca](https://github.com/intility/off_broadway_emqtt/commit/7ed52ca145ae7d7238064b8d3bfb32feb18bda01))
* typo ([addc6d4](https://github.com/intility/off_broadway_emqtt/commit/addc6d497bc9197f2e19f2f476fbf6370c97376b))


### Code Refactoring

* **connection:** Extract client ID generation to public function ([43a4ec0](https://github.com/intility/off_broadway_emqtt/commit/43a4ec0a18068c8a5ef54edee4049a1c1db2f722))
* Improve ack_ref handling and fix typespec accuracy ([45ee2ac](https://github.com/intility/off_broadway_emqtt/commit/45ee2acdad49096e33bd95ac1da88b8c0ee48f56))
* **message_handler:** remove dead callbacks ([5b7e38d](https://github.com/intility/off_broadway_emqtt/commit/5b7e38dae082bd74c9a0b7eeebfc21154576a642))
* **producer:** Move MQTT connection from init/1 to async handler ([bc33189](https://github.com/intility/off_broadway_emqtt/commit/bc331890a7aba63a75561a7fe743929cec4a63ff))
* **producer:** Simplify MQTT producer by removing ETS buffer ([7065d41](https://github.com/intility/off_broadway_emqtt/commit/7065d410c166dd0a0fa60416a70a87da48ee19fd))
* **producer:** Validate non-blank shared_group for concurrent producers ([d8b8255](https://github.com/intility/off_broadway_emqtt/commit/d8b82552c56da55f7ec0746cda6ecd023f48107e))


### Documentation

* add override: true to readme ([1093325](https://github.com/intility/off_broadway_emqtt/commit/1093325917391f531abbfefb6484c20afcd2193f))
* remove defaults from README example ([4472c92](https://github.com/intility/off_broadway_emqtt/commit/4472c92708a4b0f563cabea36229d5948b3b2fb2))
* Update changelog release dates and improve reconnection guidance ([ae8ed9c](https://github.com/intility/off_broadway_emqtt/commit/ae8ed9cd707a1980142d006a007c7c0c164985cb))
* Update dependency installation instructions ([d6f50a1](https://github.com/intility/off_broadway_emqtt/commit/d6f50a1117c8faa88c9d55090da4cf23a29e47c6))
* update description for why credentials are committed ([0fc3160](https://github.com/intility/off_broadway_emqtt/commit/0fc316075c1b23fb7eb7bfb19894192846c8103a))
* update docs ([7bdfc83](https://github.com/intility/off_broadway_emqtt/commit/7bdfc83137af8f8a7ef5520af96ec9edd2065cda))
* update docs ([3f504d3](https://github.com/intility/off_broadway_emqtt/commit/3f504d37e0595c0982c047cba313be293886cfc8))
* update installation instructions in readme file ([1e9e663](https://github.com/intility/off_broadway_emqtt/commit/1e9e66374452888d59faf8631e85ca7477654669))
* Update license badge to Apache 2.0 ([e82be7d](https://github.com/intility/off_broadway_emqtt/commit/e82be7d003d8645651ea3206f341f7801bc794ca))
* update README ([d84e9c4](https://github.com/intility/off_broadway_emqtt/commit/d84e9c478002532474d5a3f618482af4ac7afcb1))
* update README ([2efd585](https://github.com/intility/off_broadway_emqtt/commit/2efd585a8685868e234ee5eea4fbeacd85d37498))
* update README ([ef4d5e5](https://github.com/intility/off_broadway_emqtt/commit/ef4d5e52e98362d37d803226c23b04ad2e3dbda3))
* update README ([48b62ca](https://github.com/intility/off_broadway_emqtt/commit/48b62ca3671d0d4cbae120aaa6291e1fa3a60bc4))
* update README ([f30f592](https://github.com/intility/off_broadway_emqtt/commit/f30f592a0ebc06d34ae49c7311dc1c32d0eff0cd))
* update README and changelog for v0.3.0 release ([1be0fdc](https://github.com/intility/off_broadway_emqtt/commit/1be0fdc5dd7a544a1da36c0ecf92e41cf1ff5af6))
* Update release date for v0.2.0 in Changelog ([07cb6fd](https://github.com/intility/off_broadway_emqtt/commit/07cb6fd5d72b7a9bc8ec23be9a72804fa6e632a3))
* update url ([2e45836](https://github.com/intility/off_broadway_emqtt/commit/2e4583646ab3a43080c75a98f5c9b0410bde2140))


### Build System

* **deps:** Upgrade dependencies ([17f1afb](https://github.com/intility/off_broadway_emqtt/commit/17f1afbe463322204c25e626b54da1dbfb6b81a1))


### CI

* Add release automation and modernize CI workflows ([3a5e601](https://github.com/intility/off_broadway_emqtt/commit/3a5e60134f32f7ddefc411d73b326adbed91f98e))
* Rename CI pipeline to Elixir CI ([de2789b](https://github.com/intility/off_broadway_emqtt/commit/de2789b2bc16d69dccd9013071cc46e34aad2f4b))
* Update GitHub Actions and Elixir/OTP versions ([809fd59](https://github.com/intility/off_broadway_emqtt/commit/809fd59574c25d12b930a22ecd6d0463b562b05f))
* Update GitHub Actions runner to Ubuntu 22.04 ([2aaeb99](https://github.com/intility/off_broadway_emqtt/commit/2aaeb99ea9897f0b790c44637d0ca4f44c9c4733))
* **workflows:** Update Elixir CI to use Ubuntu 24.04 and newer OTP versions ([e1f3ba3](https://github.com/intility/off_broadway_emqtt/commit/e1f3ba395084aeff4ac511a951edb6b0a655f294))


### Tests

* update tests ([52df95e](https://github.com/intility/off_broadway_emqtt/commit/52df95e2f640ccd7a8adb91d2324bb50220291d8))

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
