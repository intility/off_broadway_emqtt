defmodule OffBroadway.EMQTT.ProducerTest do
  use ExUnit.Case, async: false
  # import ExUnit.CaptureLog

  require Logger
  # alias OffBroadway.EMQTT.Producer

  defmodule MessageServer do
    def start_link, do: Agent.start_link(fn -> [] end)
  end

  defmodule Forwarder do
    use Broadway

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def handle_message(_, message, %{test_pid: pid}) do
      send(pid, {:message_handled, message.data, message.metadata})
      message
    end

    def handle_batch(_, messages, _, _), do: messages
  end

  defp prepare_for_start_module_opts(module_opts) do
    {:ok, message_server} = MessageServer.start_link()
    {:ok, pid} = start_broadway(message_server)

    try do
      OffBroadway.EMQTT.Producer.prepare_for_start(Forwarder,
        producer: [
          module: {OffBroadway.EMQTT.Producer, module_opts},
          concurrency: 1
        ]
      )
    after
      stop_broadway(pid)
    end
  end

  defp start_broadway(message_server, broadway_name \\ unique_name(), opts \\ []) do
    {_client, opts} = Keyword.pop(opts, :client)

    Broadway.start_link(
      Forwarder,
      broadway_opts(broadway_name, opts,
        buffer_size: 50,
        buffer_overflow_strategy: :reject,
        config: [
          host: "test.mosquitto.org",
          port: 1883,
          username: "rw",
          password: "readwrite"
        ],
        test_pid: self(),
        message_server: message_server
      )
    )
  end

  defp stop_broadway(pid) do
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
        default: [concurrency: 1]
      ],
      batchers: [
        default: [
          batch_size: 10,
          batch_timeout: 50,
          concurrency: 1
        ]
      ]
    ]
  end

  defp unique_name(), do: :"Broadway#{System.unique_integer([:positive, :monotonic])}"

  describe "prepare_for_start/2 validation" do
    test "when :host is not present" do
      assert_raise(
        ArgumentError,
        ~r/required :host option not found, received options: \[\]/,
        fn ->
          prepare_for_start_module_opts([])
        end
      )
    end
  end
end
