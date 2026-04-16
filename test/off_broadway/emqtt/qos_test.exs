defmodule OffBroadway.EMQTT.QoSTest do
  use ExUnit.Case, async: false

  alias OffBroadway.EMQTT.Test.MessageServer

  @moduletag :requires_mqtt

  @base_config [
    host: "localhost",
    port: 1884,
    username: "rw",
    password: "readwrite"
  ]

  defmodule Forwarder do
    use Broadway

    def handle_message(_, message, %{test_pid: pid}) do
      send(pid, {:message_handled, message.data, message.metadata})
      message
    end

    def handle_batch(_, messages, _, _), do: messages
  end

  defp start_broadway(client_id, topic, qos) do
    Broadway.start_link(Forwarder,
      name: :"broadway_qos_#{System.unique_integer([:positive])}",
      context: %{test_pid: self()},
      producer: [
        module:
          {OffBroadway.EMQTT.Producer,
           topics: [{topic, qos}],
           config: @base_config ++ [clientid: client_id]},
        concurrency: 1
      ],
      processors: [default: [concurrency: 1]],
      batchers: [default: [batch_size: 10, batch_timeout: 50]]
    )
  end

  defp random_client_id, do: "qos-test-#{System.unique_integer([:positive, :monotonic])}"

  describe "QoS 0 (at_most_once)" do
    test "message is received" do
      client_id = random_client_id()
      {:ok, server} = MessageServer.start_link("server-#{client_id}")
      {:ok, _broadway} = start_broadway(client_id, "qos0/test", :at_most_once)

      Process.sleep(100)
      MessageServer.push_messages(server, "qos0/test", ["hello"], 0)

      assert_receive {:message_handled, "hello", metadata}, 1000
      assert metadata.qos == 0
    end
  end

  describe "QoS 1 (at_least_once)" do
    test "message is received and metadata includes qos 1" do
      client_id = random_client_id()
      {:ok, server} = MessageServer.start_link("server-#{client_id}")
      {:ok, _broadway} = start_broadway(client_id, "qos1/test", :at_least_once)

      Process.sleep(100)
      MessageServer.push_messages(server, "qos1/test", ["hello-qos1"], 1)

      assert_receive {:message_handled, "hello-qos1", metadata}, 1000
      assert metadata.qos == 1
    end

    test "receives all multiple messages" do
      client_id = random_client_id()
      {:ok, server} = MessageServer.start_link("server-#{client_id}")
      {:ok, _broadway} = start_broadway(client_id, "qos1/multi", :at_least_once)

      Process.sleep(100)
      MessageServer.push_messages(server, "qos1/multi", ["a", "b", "c"], 1)

      payloads =
        for _ <- 1..3 do
          assert_receive {:message_handled, payload, _meta}, 1000
          payload
        end

      assert Enum.sort(payloads) == ["a", "b", "c"]
    end
  end

  describe "QoS 2 (exactly_once)" do
    test "message is received and metadata includes qos 2" do
      client_id = random_client_id()
      {:ok, server} = MessageServer.start_link("server-#{client_id}")
      {:ok, _broadway} = start_broadway(client_id, "qos2/test", :exactly_once)

      Process.sleep(100)
      MessageServer.push_messages(server, "qos2/test", ["hello-qos2"], 2)

      assert_receive {:message_handled, "hello-qos2", metadata}, 1000
      assert metadata.qos == 2
    end
  end
end
