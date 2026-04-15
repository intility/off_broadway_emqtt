defmodule OffBroadway.EMQTT.ProducerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  @broadway_opts config: [
                   host: "localhost",
                   port: 1884,
                   username: "rw",
                   password: "readwrite",
                   clientid: "producer-test"
                 ],
                 max_inflight: 100

  require Logger

  defmodule MessageServer do
    def start_link do
      with {:ok, pid} <-
             :emqtt.start_link(
               host: ~c"localhost",
               port: 1884,
               username: "rw",
               password: "readwrite",
               clientid: "message-server"
             ),
           {:ok, _} <- :emqtt.connect(pid) do
        {:ok, pid}
      end
    end

    def push_messages(server, topic, messages) do
      for message <- messages, do: :emqtt.publish(server, topic, to_iodata(message))
    end

    def to_iodata(term) when is_binary(term), do: term
    def to_iodata(term) when is_list(term), do: term
    def to_iodata(term) when is_integer(term), do: Integer.to_string(term)
    def to_iodata(term) when is_float(term), do: Float.to_string(term)
    def to_iodata(term), do: :erlang.term_to_binary(term)
  end

  defmodule Forwarder do
    use Broadway

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def handle_message(_, message, %{test_pid: pid}) do
      send(pid, {:message_handled, message.data, message.metadata})
      message
    end

    def handle_batch(_, messages, _, %{test_pid: pid}) do
      send(pid, {:batch_handled, length(messages)})
      messages
    end
  end

  defp prepare_for_start_module_opts(module_opts) do
    OffBroadway.EMQTT.Producer.prepare_for_start(Forwarder,
      name: :test_broadway,
      producer: [
        module: {OffBroadway.EMQTT.Producer, module_opts},
        concurrency: 1
      ]
    )
  end

  defp start_broadway(_message_server, broadway_name, opts) do
    Broadway.start_link(
      Forwarder,
      broadway_opts(
        broadway_name,
        opts,
        @broadway_opts ++ [topics: [{"test", :at_least_once}]]
      )
    )
  end

  defp stop_process(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :normal)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
      {:message_handled, _, _} -> :ok
    after
      1000 -> :ok
    end
  end

  defp broadway_opts(broadway_name, opts, producer_opts) do
    [
      name: broadway_name,
      context: %{test_pid: self()},
      producer: [
        module: {OffBroadway.EMQTT.Producer, Keyword.merge(producer_opts, opts)},
        rate_limiting: [allowed_messages: 1000, interval: 1000],
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 10]
      ],
      batchers: [
        default: [
          batch_size: 100,
          batch_timeout: 50,
          concurrency: 5
        ]
      ]
    ]
  end

  defp unique_name(), do: :"Broadway#{System.unique_integer([:positive, :monotonic])}"
  defp random_alphastr(n), do: Enum.to_list(?a..?z) |> Enum.take_random(n) |> to_string()

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

  describe "Connection QoS ack API" do
    test "pubcomp/2 and puback/2 are exported" do
      Code.ensure_loaded!(OffBroadway.EMQTT.Connection)
      assert function_exported?(OffBroadway.EMQTT.Connection, :pubcomp, 2)
      assert function_exported?(OffBroadway.EMQTT.Connection, :puback, 2)
    end
  end

  describe "MessageHandler behaviour" do
    test "only defines handle_message/3 callback" do
      callbacks = OffBroadway.EMQTT.MessageHandler.behaviour_info(:callbacks)
      assert {:handle_message, 3} in callbacks
      refute {:handle_connect, 1} in callbacks
      refute {:handle_disconnect, 1} in callbacks
      refute {:handle_pubrel, 1} in callbacks
    end
  end

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

    test "when concurrency > 1 without shared_group" do
      assert_raise(
        ArgumentError,
        ~r/shared_group is required when using concurrency > 1/,
        fn ->
          OffBroadway.EMQTT.Producer.prepare_for_start(Forwarder,
            name: :test_broadway,
            producer: [
              module: {OffBroadway.EMQTT.Producer, @broadway_opts ++ [topics: [{"test", 1}]]},
              concurrency: 2
            ]
          )
        end
      )
    end

    test "concurrency > 1 with shared_group succeeds" do
      {children, _opts} =
        OffBroadway.EMQTT.Producer.prepare_for_start(Forwarder,
          name: :test_broadway,
          producer: [
            module:
              {OffBroadway.EMQTT.Producer,
               @broadway_opts ++ [topics: [{"test", 1}], shared_group: "my_group"]},
            concurrency: 2
          ]
        )

      assert children == []
    end
  end

  describe "producer" do
    @tag :requires_mqtt
    test "receive messages" do
      client_id = random_alphastr(10)

      broadway_opts =
        @broadway_opts
        |> put_in([:config, :clientid], client_id)

      {:ok, message_server} = MessageServer.start_link()

      {:ok, pid} =
        start_broadway(message_server, unique_name(), broadway_opts ++ [topics: [{"#", :at_least_once}]])

      Process.sleep(100)

      MessageServer.push_messages(message_server, "test", 1..5)

      for _message <- 1..5 do
        assert_receive {:message_handled, _data, _metadata}, 500
      end

      stop_process(pid)
    end

    @tag :requires_mqtt
    test "emits telemetry events on connection up" do
      self = self()
      client_id = random_alphastr(10)

      broadway_opts =
        put_in(@broadway_opts, [:config, :clientid], client_id)

      {:ok, message_server} = MessageServer.start_link()

      capture_log(fn ->
        :ok =
          :telemetry.attach(
            "#{client_id}-events",
            [:off_broadway_emqtt, :connection, :up],
            fn name, measurements, metadata, _ ->
              send(self, {:telemetry_event, name, measurements, metadata})
            end,
            nil
          )
      end)

      {:ok, pid} =
        start_broadway(message_server, unique_name(), broadway_opts ++ [topics: [{"#", :at_least_once}]])

      assert_receive {:telemetry_event, [:off_broadway_emqtt, :connection, :up], %{time: _},
                      %{client_id: _, producer_index: 0}},
                     500

      :ok = :telemetry.detach("#{client_id}-events")
      stop_process(pid)
    end

    @tag :requires_mqtt
    test "stops the emqtt server when draining" do
      {:ok, message_server} = MessageServer.start_link()
      {:ok, pid} = start_broadway(message_server, unique_name(), @broadway_opts ++ [topics: [{"#", :at_least_once}]])

      Process.sleep(100)
      Broadway.stop(pid, :normal)

      stop_process(pid)
    end
  end
end
