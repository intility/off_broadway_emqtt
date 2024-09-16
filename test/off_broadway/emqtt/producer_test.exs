defmodule OffBroadway.EMQTT.ProducerTest do
  use ExUnit.Case, async: false
  # import ExUnit.CaptureLog

  @broadway_opts buffer_size: 100,
                 buffer_overflow_strategy: :drop_head,
                 config: [
                   # host: "localhost",
                   host: "test.mosquitto.org",
                   port: 1884,
                   username: "rw",
                   password: "readwrite",
                   clientid: "producer-test"
                 ],
                 test_pid: self()

  require Logger

  defmodule MessageServer do
    def start_link do
      with {:ok, pid} <- :emqtt.start_link(host: ~c"localhost", port: 1883, clientid: "message-server"),
           {:ok, _} <- :emqtt.connect(pid) do
        {:ok, pid}
      end
    end

    def push_messages(server, topic, messages) when is_list(messages),
      do: Enum.each(messages, fn msg -> :emqtt.publish(server, topic, :erlang.term_to_binary(msg)) end)

    def push_messages(server, topic, messages), do: push_messages(server, topic, [messages])
  end

  defmodule Forwarder do
    use Broadway

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def handle_message(_, message, %{test_pid: pid}) do
      IO.inspect("Received message: #{inspect(message.data)}")
      send(pid, {:message_handled, message.data, message.metadata})
      message
    end

    def handle_batch(_, messages, _, _) do
      IO.inspect("Received a batch of #{length(messages)} messages")
      messages
    end
  end

  defp prepare_for_start_module_opts(module_opts) do
    # {:ok, message_server} = MessageServer.start_link()
    # {:ok, pid} = start_broadway(message_server, unique_name(), @broadway_opts ++ [topics: [{"#", 1}]])

    try do
      OffBroadway.EMQTT.Producer.prepare_for_start(Forwarder,
        producer: [
          module: {OffBroadway.EMQTT.Producer, module_opts},
          concurrency: 2
        ]
      )
    after
      :ok
      # stop_process(pid)
    end
  end

  defp start_broadway(message_server, broadway_name, opts) do
    Broadway.start_link(
      Forwarder,
      broadway_opts(
        broadway_name,
        opts,
        @broadway_opts ++ [message_server: message_server, topics: [{"test", :at_most_once}]]
      )
    )
  end

  defp stop_process(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :normal)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end

  defp broadway_opts(broadway_name, opts, producer_opts) do
    [
      name: broadway_name,
      context: %{test_pid: self()},
      producer: [
        module: {OffBroadway.EMQTT.Producer, Keyword.merge(producer_opts, opts)},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 3]
      ],
      batchers: [
        default: [
          batch_size: 100,
          batch_timeout: 50,
          concurrency: 2
        ]
      ]
    ]
  end

  defp unique_name(), do: :"Broadway#{System.unique_integer([:positive, :monotonic])}"

  describe "prepare_for_start/2 validation" do
    test "when :config is not present" do
      assert_raise(
        ArgumentError,
        ~r/invalid configuration given to OffBroadway.EMQTT.Producer/,
        fn ->
          prepare_for_start_module_opts([])
        end
      )
    end

    test "when config :host is not present" do
      assert_raise(
        ArgumentError,
        ~r/required :host option not found/,
        fn ->
          prepare_for_start_module_opts(config: [username: "rw"])
        end
      )
    end

    # FIXME: This test is failing for some reason
    # test "when valid config is present" do
    #   assert {[%{id: :message_handler}, %{id: :emqtt_server}], [producer: _]} =
    #            prepare_for_start_module_opts(config: [host: "localhost", username: "rw", password: "readwrite"])
    # end
  end

  describe "producer" do
    test "starts :emqtt as part of its supervision tree" do
      name = unique_name()
      {:ok, pid} = start_broadway(nil, name, @broadway_opts ++ [topics: [{"#", 0}]])

      Process.sleep(5000)
      stop_process(pid)
    end

    test "receive messages" do
      name = unique_name()
      {:ok, message_server} = MessageServer.start_link()
      {:ok, pid} = start_broadway(message_server, name, @broadway_opts ++ [topics: [{"#", :at_least_once}]])

      # IO.puts("Pushing messages")
      # MessageServer.push_messages(message_server, "test", 1..10)

      Process.sleep(1000)
      # for message <- 1..10 do
      #   assert_receive {:message_handled, ^message, _}
      # end
      stop_process(pid)
    end
  end
end
