defmodule OffBroadway.EMQTT.Producer do
  @moduledoc """
  A Broadway producer for MQTT using [emqtt](https://github.com/emqx/emqtt).

  Each producer instance maintains its own MQTT connection with protocol-level
  backpressure via `max_inflight` and delayed acknowledgements.

  ## Producer options

  #{NimbleOptions.docs(OffBroadway.EMQTT.Options.definition())}

  ## Backpressure

  This producer uses MQTT's `max_inflight` setting for backpressure. The broker
  will not send more than `max_inflight` unacknowledged QoS 1/2 messages.
  Messages are only acknowledged after Broadway successfully processes them.

  For QoS 0 messages, there is no protocol-level backpressure. Consider using
  QoS 1 for high-throughput scenarios.

  ## Shared Subscriptions

  When using `concurrency > 1`, you must configure a `shared_group` to distribute
  messages across producer instances. Without shared subscriptions, each producer
  would receive all messages (duplicates).

  ## Reconnection

  By default, if the MQTT connection is lost the producer stops and Broadway's supervisor
  restarts it, which creates a fresh connection and re-subscribes to all topics.

  You can instead configure emqtt's built-in reconnect via `config: [reconnect: :infinity, ...]`.
  If you do this, you MUST also set `clean_start: false` - otherwise the broker discards the
  session on reconnect and no messages will arrive after the reconnect completes.

  ## Telemetry

  This library exposes the following telemetry events:

    * `[:off_broadway_emqtt, :receive_message, :ack]` - Dispatched when acknowledging
      a message to the MQTT broker.

      * measurement: `%{time: System.system_time, count: 1}`
      * metadata: `%{topic: string, qos: integer, status: :on_success | :on_failure}`

    * `[:off_broadway_emqtt, :connection, :up]` - Dispatched when connected to broker.

      * measurement: `%{time: System.system_time}`
      * metadata: `%{client_id: string, producer_index: integer}`

    * `[:off_broadway_emqtt, :connection, :down]` - Dispatched when connection lost.

      * measurement: `%{time: System.system_time}`
      * metadata: `%{client_id: string, producer_index: integer, reason: term}`
  """

  use GenStage
  require Logger

  alias Broadway.Producer
  alias OffBroadway.EMQTT.{Connection, Acknowledger}
  alias NimbleOptions.ValidationError

  @behaviour Producer

  defstruct [
    :emqtt_pid,
    :emqtt_ref,
    :config,
    :topics,
    :shared_group,
    :max_inflight,
    :producer_index,
    :broadway_name,
    :message_handler,
    :client_id
  ]

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    config = opts[:config]
    producer_index = opts[:producer_index] || 0
    max_inflight = opts[:max_inflight] || 100

    emqtt_config =
      config
      |> Keyword.put(:max_inflight, max_inflight)

    case Connection.start_link(emqtt_config, producer_index) do
      {:ok, emqtt_pid} ->
        emqtt_ref = Process.monitor(emqtt_pid)

        case Connection.subscribe(emqtt_pid, opts[:shared_group], opts[:topics]) do
          :ok ->
            client_id = Keyword.get(config, :clientid, "unknown")

            emit_telemetry(:up, %{
              client_id: client_id,
              producer_index: producer_index
            })

            state = %__MODULE__{
              emqtt_pid: emqtt_pid,
              emqtt_ref: emqtt_ref,
              config: config,
              topics: opts[:topics],
              shared_group: opts[:shared_group],
              max_inflight: max_inflight,
              producer_index: producer_index,
              broadway_name: opts[:broadway_name],
              message_handler: opts[:message_handler],
              client_id: client_id
            }

            {:producer, state}

          {:error, reason} ->
            {:stop, {:subscribe_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:connection_failed, reason}}
    end
  end

  @impl Producer
  def prepare_for_start(_module, broadway_opts) do
    {producer_module, client_opts} = broadway_opts[:producer][:module]

    case NimbleOptions.validate(client_opts, OffBroadway.EMQTT.Options.definition()) do
      {:ok, opts} ->
        broadway_name = Keyword.fetch!(broadway_opts, :name)
        concurrency = get_in(broadway_opts, [:producer, :concurrency]) || 1

        validate_shared_group!(opts[:shared_group], concurrency)

        :persistent_term.put(broadway_name, %{
          on_success: opts[:on_success],
          on_failure: opts[:on_failure]
        })

        new_opts =
          opts
          |> Keyword.put(:broadway_name, broadway_name)

        updated_broadway_opts =
          put_in(broadway_opts, [:producer, :module], {producer_module, new_opts})

        {[], updated_broadway_opts}

      {:error, error} ->
        raise ArgumentError, format_error(error)
    end
  end

  @impl Producer
  def prepare_for_draining(state) do
    if state.emqtt_pid && Process.alive?(state.emqtt_pid) do
      Connection.pause(state.emqtt_pid)
    end

    {:noreply, [], state}
  end

  @impl true
  def handle_info({:publish, mqtt_msg}, state) do
    broadway_msg = build_broadway_message(mqtt_msg, state)
    {:noreply, [broadway_msg], state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{emqtt_ref: ref} = state) do
    emit_telemetry(:down, %{
      client_id: state.client_id,
      producer_index: state.producer_index,
      reason: reason
    })

    {:stop, {:emqtt_down, reason}, state}
  end

  def handle_info({:EXIT, pid, reason}, %{emqtt_pid: pid} = state) do
    emit_telemetry(:down, %{
      client_id: state.client_id,
      producer_index: state.producer_index,
      reason: reason
    })

    {:stop, {:emqtt_exit, reason}, state}
  end

  def handle_info({:disconnected, _reason_code, _props}, state) do
    {:noreply, [], state}
  end

  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  @impl true
  def handle_demand(_demand, state) do
    {:noreply, [], state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.emqtt_pid && Process.alive?(state.emqtt_pid) do
      Process.demonitor(state.emqtt_ref, [:flush])
      Connection.disconnect(state.emqtt_pid)
    end

    :ok
  end

  defp build_broadway_message(mqtt_msg, state) do
    message_handler = get_message_handler_module(state.message_handler)
    ack_ref = state.broadway_name

    case apply(message_handler, :handle_message, [mqtt_msg, ack_ref, []]) do
      %Broadway.Message{} = msg ->
        ack_data = Acknowledger.build_ack_data(mqtt_msg, state.emqtt_pid)
        %{msg | acknowledger: {Acknowledger, ack_ref, ack_data}}

      other ->
        other
    end
  end

  defp get_message_handler_module({module, _opts}), do: module
  defp get_message_handler_module(module), do: module

  defp validate_shared_group!(nil, concurrency) when concurrency > 1 do
    raise ArgumentError, """
    shared_group is required when using concurrency > 1.

    Without shared subscriptions, each producer instance receives ALL messages,
    causing duplicates. Configure shared_group to distribute messages:

        producer: [
          module: {OffBroadway.EMQTT.Producer,
            shared_group: "my_group",
            ...
          },
          concurrency: #{concurrency}
        ]
    """
  end

  defp validate_shared_group!(_shared_group, _concurrency), do: :ok

  defp format_error(%ValidationError{keys_path: [], message: message}) do
    "invalid configuration given to OffBroadway.EMQTT.Producer.prepare_for_start/2, " <>
      message
  end

  defp format_error(%ValidationError{keys_path: keys_path, message: message}) do
    "invalid configuration given to OffBroadway.EMQTT.Producer.prepare_for_start/2 for key #{inspect(keys_path)}, " <>
      message
  end

  defp emit_telemetry(:up, metadata) do
    :telemetry.execute(
      [:off_broadway_emqtt, :connection, :up],
      %{time: System.system_time()},
      metadata
    )
  end

  defp emit_telemetry(:down, metadata) do
    :telemetry.execute(
      [:off_broadway_emqtt, :connection, :down],
      %{time: System.system_time()},
      metadata
    )
  end
end
