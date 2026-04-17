defmodule OffBroadway.EMQTT.ProducerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias OffBroadway.EMQTT.{Acknowledger, Connection, MessageHandler, Producer}
  alias OffBroadway.EMQTT.Test.MessageServer

  @broadway_opts config: [
                   host: "localhost",
                   port: 1884,
                   username: "rw",
                   password: "readwrite",
                   clientid: "producer-test"
                 ],
                 max_inflight: 100

  require Logger

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

  defmodule CustomHandler do
    alias OffBroadway.EMQTT.{Acknowledger, MessageHandler}

    @behaviour MessageHandler

    @impl MessageHandler
    def handle_message(message, ack_ref, _opts) do
      message = Map.drop(message, [:via, :client_pid])
      {payload, metadata} = Map.pop(message, :payload)

      %Broadway.Message{
        data: payload,
        metadata: Map.put(metadata, :custom, true),
        acknowledger: {Acknowledger, ack_ref, %{}}
      }
    end
  end

  defp prepare_for_start_module_opts(module_opts) do
    Producer.prepare_for_start(Forwarder,
      name: :test_broadway,
      producer: [
        module: {Producer, module_opts},
        concurrency: 1
      ]
    )
  end

  defp start_broadway(broadway_name, opts) do
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
        module: {Producer, Keyword.merge(producer_opts, opts)},
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

  defp unique_name, do: :"Broadway#{System.unique_integer([:positive, :monotonic])}"
  defp random_alphastr(n), do: Enum.to_list(?a..?z) |> Enum.take_random(n) |> to_string()

  describe "Acknowledger.build_ack_data/2" do
    test "builds ack data map with qos, packet_id, topic and pid" do
      msg = %{qos: 2, packet_id: 42, topic: "test/topic", payload: "hello"}
      pid = self()

      ack_data = Acknowledger.build_ack_data(msg, pid)

      assert ack_data.qos == 2
      assert ack_data.packet_id == 42
      assert ack_data.topic == "test/topic"
      assert ack_data.emqtt_pid == pid
    end

    test "defaults qos to 0 when missing" do
      ack_data = Acknowledger.build_ack_data(%{topic: "t"}, self())
      assert ack_data.qos == 0
    end
  end

  describe "Connection QoS ack API" do
    test "pubcomp/2 and puback/2 are exported" do
      Code.ensure_loaded!(Connection)
      assert function_exported?(Connection, :pubcomp, 2)
      assert function_exported?(Connection, :puback, 2)
    end
  end

  describe "MessageHandler behaviour" do
    test "only defines handle_message/3 callback" do
      callbacks = MessageHandler.behaviour_info(:callbacks)
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
          prepare_for_start_module_opts(topics: [{"test", 1}], config: [username: "rw"])
        end
      )
    end

    test "when topics is an empty list" do
      assert_raise(
        ArgumentError,
        ~r/must not be empty/,
        fn ->
          prepare_for_start_module_opts(topics: [], config: [host: "localhost"])
        end
      )
    end

    test "when concurrency > 1 without shared_group" do
      assert_raise(
        ArgumentError,
        ~r/shared_group is required when using concurrency > 1/,
        fn ->
          Producer.prepare_for_start(Forwarder,
            name: :test_broadway,
            producer: [
              module: {Producer, @broadway_opts ++ [topics: [{"test", 1}]]},
              concurrency: 2
            ]
          )
        end
      )
    end

    test "concurrency > 1 with shared_group succeeds" do
      {children, _opts} =
        Producer.prepare_for_start(Forwarder,
          name: :test_broadway,
          producer: [
            module: {Producer, @broadway_opts ++ [topics: [{"test", 1}], shared_group: "my_group"]},
            concurrency: 2
          ]
        )

      assert children == []
    end
  end

  describe "producer" do
    test "logs an error when broker is unreachable" do
      name = unique_name()
      test_pid = self()

      log =
        capture_log(fn ->
          # Spawn an unlinked process so the inevitable exit from Broadway's
          # failed start does not propagate to the test process.
          pid =
            spawn(fn ->
              try do
                Broadway.start_link(Forwarder,
                  name: name,
                  context: %{test_pid: test_pid},
                  producer: [
                    module:
                      {Producer,
                       topics: [{"test", :at_least_once}],
                       config: [host: "localhost", port: 9999, clientid: "unreachable-test"]},
                    concurrency: 1
                  ],
                  processors: [default: [concurrency: 1]],
                  batchers: [default: [batch_size: 10, batch_timeout: 50]]
                )
              catch
                :exit, _ -> :ok
              end
            end)

          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            2000 -> :ok
          end
        end)

      assert log =~ "Failed to connect to MQTT broker"
      assert log =~ "9999"
      assert log =~ "localhost"
    end

    @tag :requires_mqtt
    test "receive messages" do
      client_id = random_alphastr(10)

      broadway_opts =
        @broadway_opts
        |> put_in([:config, :clientid], client_id)

      {:ok, message_server} = MessageServer.start_link()

      {:ok, pid} =
        start_broadway(unique_name(), broadway_opts ++ [topics: [{"#", :at_least_once}]])

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
        start_broadway(unique_name(), broadway_opts ++ [topics: [{"#", :at_least_once}]])

      expected_client_id = "#{client_id}_0"

      assert_receive {:telemetry_event, [:off_broadway_emqtt, :connection, :up], %{time: _},
                      %{client_id: ^expected_client_id, producer_index: 0}},
                     500

      :ok = :telemetry.detach("#{client_id}-events")
      stop_process(pid)
    end

    @tag :requires_mqtt
    test "stops the emqtt server when draining" do
      broadway_opts = put_in(@broadway_opts, [:config, :clientid], random_alphastr(10))
      {:ok, pid} = start_broadway(unique_name(), broadway_opts ++ [topics: [{"#", :at_least_once}]])

      Process.sleep(100)
      Broadway.stop(pid, :normal)

      stop_process(pid)
    end

    @tag :requires_mqtt
    test "emits connection down telemetry when emqtt process dies" do
      self = self()
      client_id = random_alphastr(10)
      broadway_name = unique_name()

      broadway_opts = put_in(@broadway_opts, [:config, :clientid], client_id)

      :telemetry.attach(
        "#{client_id}-down",
        [:off_broadway_emqtt, :connection, :down],
        fn _name, _measurements, metadata, _ ->
          send(self, {:connection_down, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("#{client_id}-down") end)

      {:ok, pid} =
        start_broadway(broadway_name, broadway_opts ++ [topics: [{"#", :at_least_once}]])

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            Broadway.stop(pid, :normal)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Sleep briefly to allow the emqtt connection to establish before we inspect it.
      # Process.sleep(200) is used instead of waiting for a telemetry :up event since
      # that event is already covered by another test.
      Process.sleep(200)

      producer_pid = Broadway.producer_names(broadway_name) |> List.first() |> Process.whereis()

      # NOTE: This traverses private internals of GenStage (:state) and Broadway
      # (:module_state). May break on dependency upgrades.
      %{state: %{module_state: %{emqtt_pid: emqtt_pid}}} = :sys.get_state(producer_pid)

      Process.exit(emqtt_pid, :kill)

      assert_receive {:connection_down, %{client_id: _, producer_index: 0}}, 1000
    end

    @tag :requires_mqtt
    test "emits ack telemetry after successful message processing" do
      self = self()
      client_id = random_alphastr(10)

      broadway_opts = put_in(@broadway_opts, [:config, :clientid], client_id)

      :telemetry.attach(
        "#{client_id}-ack",
        [:off_broadway_emqtt, :receive_message, :ack],
        fn _name, measurements, metadata, _ ->
          send(self, {:ack_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("#{client_id}-ack") end)

      {:ok, message_server} = MessageServer.start_link()

      {:ok, pid} =
        start_broadway(unique_name(), broadway_opts ++ [topics: [{"ack/telemetry/#{client_id}", :at_least_once}]])

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            Broadway.stop(pid, :normal)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Sleep briefly to allow the emqtt connection and subscription to establish
      # before publishing the test message.
      Process.sleep(200)
      MessageServer.push_messages(message_server, "ack/telemetry/#{client_id}", ["payload"], 1)

      assert_receive {:ack_event, %{count: 1}, %{status: :on_success, qos: 1}}, 2000
    end

    @tag :requires_mqtt
    test "cleans up persistent_term entry on stop" do
      broadway_name = unique_name()
      broadway_opts = put_in(@broadway_opts, [:config, :clientid], random_alphastr(10))
      ack_ref = {broadway_name, 0}

      {:ok, pid} =
        start_broadway(broadway_name, broadway_opts ++ [topics: [{"#", :at_least_once}]])

      # Term should exist while Broadway is running.
      assert is_map(:persistent_term.get(ack_ref))

      ref = Process.monitor(pid)
      Broadway.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000

      # Term should be erased after the pipeline stops.
      assert_raise ArgumentError, fn -> :persistent_term.get(ack_ref) end
    end

    @tag :requires_mqtt
    test "uses custom message_handler to transform messages" do
      client_id = random_alphastr(10)

      broadway_opts =
        @broadway_opts
        |> put_in([:config, :clientid], client_id)
        |> Keyword.put(:message_handler, CustomHandler)

      {:ok, message_server} = MessageServer.start_link()

      {:ok, pid} =
        start_broadway(unique_name(), broadway_opts ++ [topics: [{"custom/handler/#{client_id}", :at_least_once}]])

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            Broadway.stop(pid, :normal)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      Process.sleep(100)
      MessageServer.push_messages(message_server, "custom/handler/#{client_id}", ["hello"], 1)

      assert_receive {:message_handled, "hello", metadata}, 1000
      assert metadata.custom == true
    end
  end
end
