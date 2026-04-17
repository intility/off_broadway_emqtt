defmodule OffBroadway.EMQTT.RedeliveryTest do
  use ExUnit.Case, async: false

  alias OffBroadway.EMQTT.Test.MessageServer

  @base_config [
    host: "localhost",
    port: 1884,
    username: "rw",
    password: "readwrite",
    # clean_start: false is already the default, listed here for clarity.
    clean_start: false
  ]

  defmodule FailingForwarder do
    use Broadway

    def handle_message(_, message, %{test_pid: pid}) do
      send(pid, {:received, message.data})
      Broadway.Message.failed(message, "deliberate test failure")
    end

    def handle_batch(_, messages, _, _), do: messages
  end

  defmodule SucceedingForwarder do
    use Broadway

    def handle_message(_, message, %{test_pid: pid}) do
      send(pid, {:received, message.data})
      message
    end

    def handle_batch(_, messages, _, _), do: messages
  end

  defp start_broadway(forwarder, client_id, on_failure, on_success) do
    Broadway.start_link(forwarder,
      name: :"broadway_redeliver_#{System.unique_integer([:positive])}",
      context: %{test_pid: self()},
      producer: [
        module:
          {OffBroadway.EMQTT.Producer,
           topics: [{"redelivery/test/#{client_id}", :at_least_once}],
           on_failure: on_failure,
           on_success: on_success,
           config: @base_config ++ [clientid: client_id]},
        concurrency: 1
      ],
      processors: [default: [concurrency: 1]],
      batchers: [default: [batch_size: 10, batch_timeout: 50]]
    )
  end

  test "unACKed QoS 1 message is redelivered after producer restart" do
    client_id = MessageServer.unique_id("redeliver")
    topic = "redelivery/test/#{client_id}"

    # Phase 1: start with a failing forwarder. Messages are received but not ACKed.
    {:ok, broadway1} = start_broadway(FailingForwarder, client_id, :noop, :ack)

    on_exit(fn ->
      if Process.alive?(broadway1) do
        try do
          Broadway.stop(broadway1, :normal)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, server} = MessageServer.start_link("server-#{client_id}")

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :normal)
    end)

    Process.sleep(100)
    MessageServer.push_messages(server, topic, ["important-message"], 1)

    assert_receive {:received, "important-message"}, 1000

    # Guard: ensure the message was not delivered twice within Phase 1.
    refute_receive {:received, _}, 200

    # Stop Broadway - emqtt disconnects without ACKing the message.
    ref = Process.monitor(broadway1)
    Broadway.stop(broadway1, :normal)
    assert_receive {:DOWN, ^ref, :process, ^broadway1, _}, 2000

    # Small sleep to ensure the broker registers the disconnect before we reconnect.
    Process.sleep(500)

    # Phase 2: restart with same clientid and a succeeding forwarder.
    # The broker still has the message as unACKed and will redeliver it.
    # Both phases use concurrency: 1 so the effective broker clientid is
    # "#{client_id}_0". The same suffix must be used in both phases for the
    # broker to redeliver the unACKed message to the second session.
    {:ok, broadway2} = start_broadway(SucceedingForwarder, client_id, :noop, :ack)

    on_exit(fn ->
      if Process.alive?(broadway2) do
        try do
          Broadway.stop(broadway2, :normal)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    assert_receive {:received, "important-message"}, 5000
  end
end
