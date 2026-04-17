defmodule OffBroadway.EMQTT.BackpressureTest do
  use ExUnit.Case, async: false

  alias OffBroadway.EMQTT.Test.MessageServer

  @moduletag :requires_mqtt

  # MQTT v5 is required for broker-side subscriber flow control via Receive-Maximum.
  # When proto_ver: :v5, the producer automatically sets Receive-Maximum in the
  # CONNECT properties to match max_inflight. Without MQTT v5, the broker pushes
  # all messages immediately regardless of unACKed count.
  @base_config [
    host: "localhost",
    port: 1884,
    username: "rw",
    password: "readwrite",
    proto_ver: :v5
  ]

  # This Forwarder blocks each message until the gate agent allows it through.
  # The gate holds a count; handle_message decrements it. When the count is 0,
  # the processor spins (polling every 50ms) until the test increments the gate.
  defmodule BlockingForwarder do
    use Broadway

    def handle_message(_, message, %{test_pid: pid, gate: gate}) do
      send(pid, {:in_flight, message.data})
      wait_for_gate(gate)
      message
    end

    def handle_batch(_, messages, _, _), do: messages

    defp wait_for_gate(gate) do
      case Agent.get_and_update(gate, fn
             0 -> {false, 0}
             n -> {true, n - 1}
           end) do
        true ->
          :ok

        false ->
          Process.sleep(50)
          wait_for_gate(gate)
      end
    end
  end

  test "broker respects max_inflight and does not send beyond the window" do
    client_id = MessageServer.unique_id("backpressure")
    # Use start (not start_link) so the gate agent is not linked to the test process.
    # Processor workers in other processes call the gate; if the test exits before
    # Broadway fully stops, we don't want the gate to die mid-flight.
    {:ok, gate} = Agent.start(fn -> 0 end)
    on_exit(fn -> if Process.alive?(gate), do: Agent.stop(gate) end)

    {:ok, broadway} =
      Broadway.start_link(BlockingForwarder,
        name: :"broadway_bp_#{System.unique_integer([:positive])}",
        context: %{test_pid: self(), gate: gate},
        producer: [
          module:
            {OffBroadway.EMQTT.Producer,
             topics: [{"backpressure/#{client_id}", :at_least_once}],
             max_inflight: 2,
             config: @base_config ++ [clientid: client_id]},
          concurrency: 1
        ],
        processors: [default: [concurrency: 10]],
        batchers: [default: [batch_size: 10, batch_timeout: 200]]
      )

    on_exit(fn ->
      if Process.alive?(broadway) do
        try do
          Broadway.stop(broadway, :normal)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, server} = MessageServer.start_link("server-#{client_id}")

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :normal)
    end)

    Process.sleep(150)

    # Publish 5 QoS 1 messages.
    MessageServer.push_messages(server, "backpressure/#{client_id}", ["m1", "m2", "m3", "m4", "m5"], 1)

    # With max_inflight: 2, only 2 messages should arrive before we ACK anything.
    assert_receive {:in_flight, _}, 1000
    assert_receive {:in_flight, _}, 1000

    # The 3rd message must NOT arrive yet - broker is waiting for ACKs.
    refute_receive {:in_flight, _}, 300

    # Open gate for 2: the two in-flight messages complete and ACK, freeing the window.
    Agent.update(gate, fn n -> n + 2 end)

    # Next 2 arrive.
    assert_receive {:in_flight, _}, 2000
    assert_receive {:in_flight, _}, 2000

    # Open gate for the rest.
    Agent.update(gate, fn n -> n + 10 end)
    assert_receive {:in_flight, _}, 2000

    Broadway.stop(broadway, :normal)
    Agent.stop(gate)
  end
end
