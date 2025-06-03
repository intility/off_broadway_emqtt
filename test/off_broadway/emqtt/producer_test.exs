defmodule OffBroadway.EMQTT.ProducerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  @broadway_opts buffer_size: 10_000,
                 buffer_overflow_strategy: :drop_head,
                 config: [
                   host: "localhost",
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
      producer: [
        module: {OffBroadway.EMQTT.Producer, module_opts},
        concurrency: 2
      ]
    )
  end

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

  defp stop_process(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :normal)

    # Capture EXIT or any in-flight messages
    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
      {:message_handled, _, _} -> :ok
    end
  end

  defp broadway_opts(broadway_name, opts, producer_opts) do
    [
      name: broadway_name,
      context: %{test_pid: self()},
      producer: [
        module: {OffBroadway.EMQTT.Producer, Keyword.merge(producer_opts, opts)},
        rate_limiting: [allowed_messages: 1000, interval: 1000],
        concurrency: 10
      ],
      processors: [
        default: [concurrency: 20]
      ],
      batchers: [
        default: [
          batch_size: 100,
          batch_timeout: 50,
          concurrency: 10
        ]
      ]
    ]
  end

  defp unique_name(), do: :"Broadway#{System.unique_integer([:positive, :monotonic])}"
  defp random_alphastr(n), do: Enum.to_list(?a..?z) |> Enum.take_random(n) |> to_string()

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
  end

  describe "producer" do
    test "receive messages" do
      client_id = random_alphastr(10)

      broadway_opts =
        Keyword.merge(@broadway_opts, buffer_size: 10, buffer_overflow_strategy: :drop_head)
        |> put_in([:config, :clientid], client_id)

      {:ok, message_server} = MessageServer.start_link()
      {:ok, pid} = start_broadway(message_server, unique_name(), broadway_opts ++ [topics: [{"#", :at_least_once}]])

      MessageServer.push_messages(message_server, "test", 1..5)

      for _message <- 1..5 do
        assert_receive {:message_handled, _data, _metadata}, 200
      end

      stop_process(pid)
    end

    test "durable buffer writes messages to log file" do
      self = self()
      client_id = random_alphastr(10)

      broadway_opts =
        Keyword.merge(@broadway_opts, buffer_log_dir: System.tmp_dir!(), buffer_durability: :durable)
        |> put_in([:config, :clientid], client_id)

      {:ok, message_server} = MessageServer.start_link()
      {:ok, pid} = start_broadway(message_server, unique_name(), broadway_opts ++ [topics: [{"#", :at_least_once}]])

      capture_log(fn ->
        :ok =
          :telemetry.attach(
            "#{client_id}-events",
            [:off_broadway_emqtt, :buffer, :log_write],
            fn name, measurements, metadata, _ ->
              send(self, {:telemetry_event, name, measurements, metadata})
            end,
            nil
          )
      end)

      MessageServer.push_messages(message_server, "test", 1..5)

      for _ <- 1..5 do
        assert_receive {:telemetry_event, [:off_broadway_emqtt, :buffer, :log_write], %{time: _, count: 1},
                        %{client_id: ^client_id, topic: "test", buffer_size: _}},
                       200

        assert_receive {:message_handled, _data, _metadata}, 200
      end

      :ok = :telemetry.detach("#{client_id}-events")
      stop_process(pid)
    end

    test "durable buffer attempts to replay existing messages on start" do
      self = self()
      client_id = random_alphastr(10)

      broadway_opts =
        Keyword.merge(@broadway_opts, buffer_log_dir: System.tmp_dir!(), buffer_durability: :durable)
        |> put_in([:config, :clientid], client_id)

      {:ok, message_server} = MessageServer.start_link()
      {:ok, pid} = start_broadway(message_server, unique_name(), broadway_opts ++ [topics: [{"#", :at_least_once}]])

      capture_log(fn ->
        :ok =
          :telemetry.attach(
            "#{client_id}-events",
            [:off_broadway_emqtt, :replay_buffer, :start],
            fn name, measurements, metadata, _ ->
              send(self, {:telemetry_event, name, measurements, metadata})
            end,
            nil
          )
      end)

      assert_receive {:telemetry_event, [:off_broadway_emqtt, :replay_buffer, :start], _, %{client_id: ^client_id}},
                     200

      :ok = :telemetry.detach("#{client_id}-events")
      stop_process(pid)
    end

    test "reject message when buffer is full" do
      self = self()
      client_id = random_alphastr(10)

      broadway_opts =
        Keyword.merge(@broadway_opts, buffer_size: 5, buffer_overflow_strategy: :reject)
        |> put_in([:config, :clientid], client_id)

      {:ok, message_server} = MessageServer.start_link()
      {:ok, pid} = start_broadway(message_server, unique_name(), broadway_opts ++ [topics: [{"#", :exactly_once}]])

      capture_log(fn ->
        :ok =
          :telemetry.attach(
            "#{client_id}-events",
            [:off_broadway_emqtt, :buffer, :reject_message],
            fn name, measurements, metadata, _ ->
              send(self, {:telemetry_event, name, measurements, metadata})
            end,
            nil
          )
      end)

      MessageServer.push_messages(message_server, "test", 1..6)

      assert_receive {:telemetry_event, [:off_broadway_emqtt, :buffer, :reject_message], %{time: _, count: 1},
                      %{client_id: ^client_id, topic: "test", buffer_size: 5}},
                     200

      for _ <- 1..5, do: assert_receive({:message_handled, _, _}, 200)

      :ok = :telemetry.detach("#{client_id}-events")
      stop_process(pid)
    end

    test "drops head when buffer is full" do
      self = self()
      client_id = random_alphastr(10)

      broadway_opts =
        Keyword.merge(@broadway_opts, buffer_size: 5, buffer_overflow_strategy: :drop_head)
        |> put_in([:config, :clientid], client_id)

      {:ok, message_server} = MessageServer.start_link()
      {:ok, pid} = start_broadway(message_server, unique_name(), broadway_opts ++ [topics: [{"#", :exactly_once}]])

      capture_log(fn ->
        :ok =
          :telemetry.attach(
            "#{client_id}-events",
            [:off_broadway_emqtt, :buffer, :drop_message],
            fn name, measurements, metadata, _ ->
              send(self, {:telemetry_event, name, measurements, metadata})
            end,
            nil
          )
      end)

      MessageServer.push_messages(message_server, "test", 1..6)

      assert_receive {:telemetry_event, [:off_broadway_emqtt, :buffer, :drop_message], %{time: _, count: 1},
                      %{client_id: ^client_id, topic: "test", buffer_size: 5}},
                     200

      for _ <- 1..5, do: assert_receive({:message_handled, _, _}, 200)

      :ok = :telemetry.detach("#{client_id}-events")
      stop_process(pid)
    end

    test "emits telemetry events" do
      self = self()
      client_id = random_alphastr(10)

      broadway_opts =
        put_in(@broadway_opts, [:config, :clientid], client_id)

      {:ok, message_server} = MessageServer.start_link()
      {:ok, pid} = start_broadway(message_server, unique_name(), broadway_opts ++ [topics: [{"#", :at_least_once}]])

      capture_log(fn ->
        :ok =
          :telemetry.attach(
            "#{client_id}-events",
            [:off_broadway_emqtt, :receive_messages, :start],
            fn name, measurements, metadata, _ ->
              send(self, {:telemetry_event, name, measurements, metadata})
            end,
            nil
          )
      end)

      MessageServer.push_messages(message_server, "test", [1])

      assert_receive {:telemetry_event, [:off_broadway_emqtt, :receive_messages, :start],
                      %{system_time: _, monotonic_time: _}, %{client_id: ^client_id}},
                     200

      :ok = :telemetry.detach("#{client_id}-events")
      stop_process(pid)
    end

    test "stops the emqtt server when draining" do
      {:ok, pid} = start_broadway(nil, unique_name(), @broadway_opts ++ [topics: [{"#", :at_least_once}]])
      Broadway.stop(pid, :normal)

      stop_process(pid)
    end
  end
end
