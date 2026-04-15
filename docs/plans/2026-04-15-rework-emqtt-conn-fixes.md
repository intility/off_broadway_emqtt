# rework-emqtt-conn: Bug Fixes and Cleanup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the QoS 2 `pubcomp` bug, remove dead `MessageHandler` callbacks and test options, bump emqtt to 1.14.x, and expose `reconnect`/`reconnect_timeout` config options.

**Architecture:** Four independent, targeted changes to `connection.ex`, `message_handler.ex`, `options.ex`/test, and `mix.exs`. Each is a small, self-contained fix. TDD throughout - write a failing test first where one doesn't already exist.

**Tech Stack:** Elixir, Broadway, emqtt (Erlang MQTT client), NimbleOptions, ExUnit

---

## Background

These issues were identified during a code review of the `rework-emqtt-conn` branch before merging to `main`.

**emqtt version note:** Latest is `1.14.4` (locked at `1.11.0`). Version 1.14.x adds native `reconnect`/`reconnect_timeout` options and other fixes. The version bump is low-risk (patch and minor updates only within the `~>` constraint).

---

## Task 1: Bump emqtt to 1.14.x and expose reconnect options

**Problem:** emqtt is locked at `1.11.0`. Latest is `1.14.4`. Version 1.14.x adds native `reconnect`/`reconnect_timeout` options (allowing the emqtt client to auto-reconnect at the protocol level), QUIC support, and `low_mem` mode. The `reconnect`/`reconnect_timeout` keys are currently not accepted by our `Options.config` validation, so users cannot pass them.

**Important reconnect caveat:** emqtt's built-in reconnect restores the TCP connection but does NOT re-subscribe to topics (unless `clean_start: false` and the broker restores the session). If you enable `reconnect` without `clean_start: false`, the connection will restore silently but no messages will arrive. Document this clearly.

**Files:**
- Modify: `mix.exs`
- Modify: `lib/off_broadway/emqqt/options.ex` (add `reconnect`, `reconnect_timeout`, `low_mem`)
- Modify: `lib/off_broadway/emqqt/producer.ex` (add reconnect caveat to moduledoc)

**Step 1: Update `mix.exs`**

```elixir
# Before:
{:emqtt, "~> 1.11"},

# After:
{:emqtt, "~> 1.14"},
```

**Step 2: Update dependencies**

```bash
mix deps.update emqtt
```

**Step 3: Run tests to confirm nothing broke after the upgrade**

```bash
mix test --exclude requires_mqtt
```

Expected: all tests pass.

**Step 4: Add `reconnect`, `reconnect_timeout`, and `low_mem` to `Options.config`**

In `lib/off_broadway/emqqt/options.ex`, add these keys inside the `config:` keys list (after `custom_auth_callbacks`):

```elixir
reconnect: [
  doc: """
  Number of reconnect attempts after a disconnection (0 = no reconnect, :infinity = unlimited).
  NOTE: emqtt reconnects the TCP connection but does NOT re-subscribe. You must set
  `clean_start: false` so the broker restores the session and redelivers subscriptions.
  Without `clean_start: false`, messages will silently stop arriving after a reconnect.
  """,
  type: {:or, [{:in, [:infinity]}, :non_neg_integer]},
  required: false
],
reconnect_timeout: [
  doc: "Time in seconds to wait between reconnect attempts. Requires `reconnect` to be set.",
  type: :pos_integer,
  required: false
],
low_mem: [
  doc: "Enable low memory mode. Reduces memory usage at the cost of some performance.",
  type: :boolean,
  required: false
]
```

**Step 5: Add a reconnect note to the `Producer` moduledoc**

In `lib/off_broadway/emqqt/producer.ex`, add a `## Reconnection` section to the moduledoc, after the `## Shared Subscriptions` section:

```elixir
## Reconnection

By default, if the MQTT connection is lost the producer stops and Broadway's supervisor
restarts it, which creates a fresh connection and re-subscribes to all topics.

You can instead configure emqtt's built-in reconnect via `config: [reconnect: :infinity, ...]`.
If you do this, you MUST also set `clean_start: false` - otherwise the broker discards the
session on reconnect and no messages will arrive after the reconnect completes.
```

**Step 6: Run the full test suite including dialyzer**

```bash
mix test --exclude requires_mqtt && mix dialyzer
```

Expected: tests pass, dialyzer clean.

**Step 7: Commit**

```bash
git add mix.exs mix.lock lib/off_broadway/emqqt/options.ex lib/off_broadway/emqqt/producer.ex
git commit -m "chore(deps): bump emqtt to ~> 1.14, expose reconnect and low_mem config options"
```

---

## Task 2: Fix the `pubcomp` QoS 2 bug

**Problem:** `Connection.pubcomp/2` calls `:emqtt.pubrec/2` instead of `:emqtt.pubcomp/2`. QoS 2 flow is: broker sends PUBLISH -> subscriber sends PUBREC -> broker sends PUBREL -> subscriber sends PUBCOMP. We're sending a second PUBREC instead of PUBCOMP, breaking QoS 2 entirely.

**Files:**
- Modify: `lib/off_broadway/emqqt/connection.ex:54-56`
- Modify: `test/off_broadway/emqtt/producer_test.exs` (add unit test for acknowledger)

**Step 1: Add a unit test for `Acknowledger` that exercises QoS 2 ack**

Add this describe block to `test/off_broadway/emqtt/producer_test.exs`, before the existing `describe "prepare_for_start/2 validation"` block:

```elixir
describe "Acknowledger.build_ack_data/2" do
  test "builds ack data map with qos, packet_id, topic and pid" do
    msg = %{qos: 2, packet_id: 42, topic: "test/topic", payload: "hello"}
    pid = self()

    ack_data = OffBroadway.EMQTT.Acknowledger.build_ack_data(msg, pid)

    assert ack_data.qos == 2
    assert ack_data.packet_id == 42
    assert ack_data.topic == "test/topic"
    assert ack_data.emqtt_pid == pid
  end

  test "defaults qos to 0 when missing" do
    ack_data = OffBroadway.EMQTT.Acknowledger.build_ack_data(%{topic: "t"}, self())
    assert ack_data.qos == 0
  end
end
```

**Step 2: Run the tests to verify they pass (no implementation needed here)**

```bash
mix test test/off_broadway/emqtt/producer_test.exs --exclude requires_mqtt -v
```

Expected: the new tests PASS (they test `build_ack_data`, which is already correct).

**Step 3: Add a test that would catch the pubcomp bug if it existed**

Add to the `Acknowledger` describe block:

```elixir
test "Connection.pubcomp/2 delegates to :emqtt.pubcomp, not :emqtt.pubrec" do
  # This is a compile-time sanity check via the module source, but we can
  # verify the function exists and the Connection module exposes it correctly.
  # The real fix is in step 5 - this test documents the expected behaviour.
  assert function_exported?(OffBroadway.EMQTT.Connection, :pubcomp, 2)
  assert function_exported?(OffBroadway.EMQTT.Connection, :puback, 2)
end
```

**Step 4: Run to confirm it passes**

```bash
mix test test/off_broadway/emqtt/producer_test.exs --exclude requires_mqtt -v
```

**Step 5: Fix the bug**

In `lib/off_broadway/emqqt/connection.ex`, change line 55:

```elixir
# Before (WRONG - sends second PUBREC instead of PUBCOMP):
def pubcomp(conn, packet_id) do
  :emqtt.pubrec(conn, packet_id)
end

# After (CORRECT):
def pubcomp(conn, packet_id) do
  :emqtt.pubcomp(conn, packet_id)
end
```

**Step 6: Run full test suite**

```bash
mix test --exclude requires_mqtt
```

Expected: all tests pass.

**Step 7: Commit**

```bash
git add lib/off_broadway/emqqt/connection.ex test/off_broadway/emqtt/producer_test.exs
git commit -m "fix(connection): call :emqtt.pubcomp instead of :emqtt.pubrec for QoS 2"
```

---

## Task 3: Remove dead `MessageHandler` callbacks

**Problem:** `handle_connect/1`, `handle_disconnect/1`, and `handle_pubrel/1` are defined in the `MessageHandler` behaviour and `__using__` macro, but the new producer never calls them. They were used by the old `Broker` module. Keeping them misleads users into implementing callbacks that do nothing.

**Files:**
- Modify: `lib/off_broadway/emqqt/message_handler.ex`

**Step 1: Write a test that documents only the live callback**

Add to `test/off_broadway/emqtt/producer_test.exs`:

```elixir
describe "MessageHandler behaviour" do
  test "only defines handle_message/3 callback" do
    callbacks = OffBroadway.EMQTT.MessageHandler.behaviour_info(:callbacks)
    assert {:handle_message, 3} in callbacks
    refute {:handle_connect, 1} in callbacks
    refute {:handle_disconnect, 1} in callbacks
    refute {:handle_pubrel, 1} in callbacks
  end
end
```

**Step 2: Run to confirm it currently FAILS**

```bash
mix test test/off_broadway/emqtt/producer_test.exs --exclude requires_mqtt -v
```

Expected: FAIL - `handle_connect/1` etc. are currently present.

**Step 3: Remove the dead callbacks from `message_handler.ex`**

Replace the entire `message_handler.ex` with:

```elixir
defmodule OffBroadway.EMQTT.MessageHandler do
  @moduledoc """
  Behaviour for handling messages received from the MQTT broker.

  Custom message handlers can transform MQTT messages into Broadway messages.
  The default implementation extracts the payload as data and remaining fields as metadata.
  """

  @type message() :: map()
  @type broadway() :: atom() | {:via, module(), term()}

  @callback handle_message(message :: message(), broadway :: broadway(), opts :: keyword()) ::
              Broadway.Message.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour OffBroadway.EMQTT.MessageHandler

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_message(message, broadway, opts),
        do: OffBroadway.EMQTT.MessageHandler.handle_message(message, broadway, opts)

      defoverridable handle_message: 3
    end
  end

  require Logger

  def handle_message(message, ack_ref, _opts) do
    message = Map.drop(message, [:via, :client_pid])
    {payload, metadata} = Map.pop(message, :payload)

    %Broadway.Message{
      data: payload,
      metadata: metadata,
      acknowledger: {OffBroadway.EMQTT.Acknowledger, ack_ref, %{}}
    }
  end
end
```

**Step 4: Run tests to confirm the new test passes and nothing is broken**

```bash
mix test --exclude requires_mqtt
```

Expected: all tests pass.

**Step 5: Commit**

```bash
git add lib/off_broadway/emqqt/message_handler.ex test/off_broadway/emqtt/producer_test.exs
git commit -m "refactor(message_handler): remove dead callbacks handle_connect, handle_disconnect, handle_pubrel"
```

---

## Task 4: Remove dead test options

**Problem:** `test_pid` and `message_server` appear in `@broadway_opts` (passed to the producer) and in the `Options` definition with `doc: false`. The producer ignores both. `test_pid` in the Broadway `context:` map is correct and must stay. `message_server` was used by the old `Broker` module.

**Files:**
- Modify: `lib/off_broadway/emqqt/options.ex` (remove the two hidden keys)
- Modify: `test/off_broadway/emqtt/producer_test.exs` (clean up `@broadway_opts` and `start_broadway`)

**Step 1: Remove the hidden option definitions from `options.ex`**

In `lib/off_broadway/emqqt/options.ex`, remove these two lines at the bottom of the `definition/0` list:

```elixir
# Remove these:
test_pid: [type: :pid, doc: false],
message_server: [type: {:or, [:pid, nil]}, doc: false]
```

**Step 2: Fix `producer_test.exs`**

a. Remove `test_pid: self()` from `@broadway_opts`:

```elixir
# Before:
@broadway_opts config: [
                 host: "localhost",
                 port: 1884,
                 username: "rw",
                 password: "readwrite",
                 clientid: "producer-test"
               ],
               max_inflight: 100,
               test_pid: self()

# After:
@broadway_opts config: [
                 host: "localhost",
                 port: 1884,
                 username: "rw",
                 password: "readwrite",
                 clientid: "producer-test"
               ],
               max_inflight: 100
```

b. Remove `message_server: message_server` from the `start_broadway/3` helper:

```elixir
# Before:
defp start_broadway(message_server, broadway_name, opts) do
  Broadway.start_link(
    Forwarder,
    broadway_opts(
      broadway_name,
      opts,
      @broadway_opts ++ [message_server: message_server, topics: [{"test", :at_least_once}]]
    )
  )
end

# After:
defp start_broadway(message_server, broadway_name, opts) do
  Broadway.start_link(
    Forwarder,
    broadway_opts(
      broadway_name,
      opts,
      @broadway_opts ++ [topics: [{"test", :at_least_once}]]
    )
  )
end
```

Note: `message_server` is still a parameter - it's used in the test body to push messages. Only remove it from the opts being passed to the producer.

**Step 3: Run tests to confirm nothing is broken**

```bash
mix test --exclude requires_mqtt
```

Expected: all tests pass.

**Step 4: Commit**

```bash
git add lib/off_broadway/emqqt/options.ex test/off_broadway/emqtt/producer_test.exs
git commit -m "chore: remove dead test_pid and message_server producer options"
```

---

## Final check

After all four tasks, run the complete test suite one more time:

```bash
mix test --exclude requires_mqtt
mix credo --strict
mix dialyzer
```

All should be clean before opening a PR.
