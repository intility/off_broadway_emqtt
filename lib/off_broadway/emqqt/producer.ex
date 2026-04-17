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
  If you do this, you MUST also set `clean_start: false`. Otherwise the broker discards the
  session on reconnect and no messages will arrive after the reconnect completes.

  ## Telemetry

  This library exposes the following telemetry events:

    * `[:off_broadway_emqtt, :producer, :init]` - Dispatched when a producer instance
      has finished `init/1` and scheduled its first connection attempt.

      * measurement: `%{time: System.system_time}`
      * metadata: `%{broadway_name: term, producer_index: integer}`

    * `[:off_broadway_emqtt, :producer, :terminate]` - Dispatched when a producer
      instance is terminating (Broadway shutdown, crash, or supervisor restart).

      * measurement: `%{time: System.system_time}`
      * metadata: `%{broadway_name: term, producer_index: integer, client_id: string | nil, reason: term}`

    * `[:off_broadway_emqtt, :connection, :up]` - Dispatched when connected to broker.

      * measurement: `%{time: System.system_time}`
      * metadata: `%{client_id: string, producer_index: integer}`

    * `[:off_broadway_emqtt, :connection, :down]` - Dispatched when connection lost,
      including when the initial connect fails and when emqtt signals a disconnect
      during reconnect. See "Common `connection.down` reasons" below.

      * measurement: `%{time: System.system_time}`
      * metadata: `%{client_id: string, producer_index: integer, reason: term}`

    * `[:off_broadway_emqtt, :subscription, :success]` - Dispatched for each topic
      the broker granted a subscription on. `granted_qos` is the actual QoS the
      broker assigned, which may be lower than requested.

      * measurement: `%{time: System.system_time}`
      * metadata: `%{client_id: string, producer_index: integer, topic: string, granted_qos: 0..2}`

    * `[:off_broadway_emqtt, :subscription, :error]` - Dispatched when subscribing
      to a topic fails (either a transport error or a SUBACK reason code >= 128).

      * measurement: `%{time: System.system_time}`
      * metadata: `%{client_id: string, producer_index: integer, topic: string, reason: term}`

    * `[:off_broadway_emqtt, :receive_message, :start]` - Dispatched when a PUBLISH
      arrives from the broker, before Broadway dispatch. Pairs with
      `receive_message.ack` for end-to-end latency measurement.

      * measurement: `%{time: System.system_time, count: 1}`
      * metadata: `%{client_id: string, producer_index: integer, topic: string, qos: integer}`

    * `[:off_broadway_emqtt, :receive_message, :ack]` - Dispatched when acknowledging
      a message to the MQTT broker.

      * measurement: `%{time: System.system_time, count: 1}`
      * metadata: `%{topic: string, qos: integer, status: :on_success | :on_failure}`

  ### Common `connection.down` reasons

  The `reason` field carries the raw error returned by emqtt or the MQTT broker.
  Common values a consumer may want to pattern-match on:

    * Authentication failures
      * `:bad_username_or_password` (MQTT 3.1.1 CONNACK code 4)
      * `:not_authorized` (MQTT 3.1.1 code 5, MQTT 5 code 135)
      * `{:unacceptable_protocol_version, _}`
    * TLS/certificate failures
      * `{:tls_alert, {:unknown_ca, _}}`
      * `{:tls_alert, {:bad_certificate, _}}`
      * `{:tls_alert, {:handshake_failure, _}}` - often SNI or hostname mismatch
      * `{:tls_alert, {:certificate_expired, _}}`
    * Network/transport failures
      * `:econnrefused` - broker not listening on host:port
      * `:nxdomain` - DNS resolution failed
      * `:timeout` - CONNACK did not arrive within `connect_timeout`
      * `:closed` / `:tcp_closed` - broker closed the socket
    * Server/session failures (MQTT 5 reason codes surface as integers or atoms)
      * `:server_unavailable`, `:server_busy`, `:quota_exceeded`

  When emqtt's built-in `reconnect` is enabled, `connection.down` fires with the
  CONNACK reason code integer, not an atom.
  """

  use GenStage
  require Logger

  alias Broadway.Producer
  alias NimbleOptions.ValidationError
  alias OffBroadway.EMQTT.{Acknowledger, Connection, Options}

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
    :client_id,
    :ack_ref,
    connected?: true
  ]

  @impl true
  def init(opts) do
    # Keep init/1 cheap: the emqtt CONNECT handshake can take up to the user's
    # `connect_timeout` (default 60s), but Broadway's supervisor calls us via
    # GenServer.start_link whose default timeout is 5s and which Broadway does
    # not expose for override. Doing the connect here would crash Broadway's
    # start_link for any broker that responds slowly. Instead we set up state,
    # install the ack options, and kick off the connect asynchronously.
    Process.flag(:trap_exit, true)

    producer_index = get_in(opts, [:broadway, :index]) || 0
    max_inflight = opts[:max_inflight] || 100
    ack_ref = {opts[:broadway_name], producer_index}

    :persistent_term.put(ack_ref, %{
      on_success: opts[:on_success],
      on_failure: opts[:on_failure]
    })

    state = %__MODULE__{
      config: opts[:config],
      topics: opts[:topics],
      shared_group: opts[:shared_group],
      max_inflight: max_inflight,
      producer_index: producer_index,
      broadway_name: opts[:broadway_name],
      message_handler: opts[:message_handler],
      ack_ref: ack_ref,
      connected?: false
    }

    emit_telemetry([:producer, :init], %{
      broadway_name: state.broadway_name,
      producer_index: producer_index
    })

    send(self(), :connect)
    {:producer, state}
  end

  @impl Producer
  def prepare_for_start(_module, broadway_opts) do
    {producer_module, client_opts} = broadway_opts[:producer][:module]

    case NimbleOptions.validate(client_opts, Options.definition()) do
      {:ok, opts} ->
        broadway_name = Keyword.fetch!(broadway_opts, :name)
        concurrency = get_in(broadway_opts, [:producer, :concurrency]) || 1

        validate_shared_group!(opts[:shared_group], concurrency)

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
  def handle_info(:connect, state) do
    emqtt_config =
      state.config
      |> Keyword.put(:max_inflight, state.max_inflight)
      |> maybe_set_receive_maximum(state.max_inflight)

    with {:ok, emqtt_pid, client_id} <- Connection.start_link(emqtt_config, state.producer_index),
         emqtt_ref = Process.monitor(emqtt_pid),
         {:ok, granted} <- Connection.subscribe(emqtt_pid, state.shared_group, state.topics) do
      emit_telemetry([:connection, :up], %{
        client_id: client_id,
        producer_index: state.producer_index
      })

      for {topic, granted_qos} <- granted do
        emit_telemetry([:subscription, :success], %{
          client_id: client_id,
          producer_index: state.producer_index,
          topic: topic,
          granted_qos: granted_qos
        })
      end

      {:noreply, [],
       %{
         state
         | emqtt_pid: emqtt_pid,
           emqtt_ref: emqtt_ref,
           client_id: client_id,
           connected?: true
       }}
    else
      {:error, {:subscribe_failed, topic, subscribe_reason} = reason} ->
        emit_telemetry([:subscription, :error], %{
          client_id: Keyword.get(state.config, :clientid),
          producer_index: state.producer_index,
          topic: topic,
          reason: subscribe_reason
        })

        {:stop, reason, state}

      {:error, reason} ->
        Logger.error(
          "Failed to connect to MQTT broker " <>
            "(#{inspect(Keyword.get(state.config, :host))}:#{Keyword.get(state.config, :port, 1883)}): " <>
            "#{inspect(reason)}"
        )

        emit_telemetry([:connection, :down], %{
          client_id: Keyword.get(state.config, :clientid),
          producer_index: state.producer_index,
          reason: reason
        })

        {:stop, {:connection_failed, reason}, state}
    end
  end

  def handle_info({:publish, mqtt_msg}, state) do
    emit_telemetry(
      [:receive_message, :start],
      %{
        client_id: state.client_id,
        producer_index: state.producer_index,
        topic: mqtt_msg[:topic],
        qos: mqtt_msg[:qos] || 0
      },
      %{count: 1}
    )

    broadway_msg = build_broadway_message(mqtt_msg, state)
    {:noreply, [broadway_msg], state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{emqtt_ref: ref} = state) do
    emit_telemetry([:connection, :down], %{
      client_id: state.client_id,
      producer_index: state.producer_index,
      reason: reason
    })

    {:stop, {:emqtt_down, reason}, state}
  end

  def handle_info({:EXIT, pid, reason}, %{emqtt_pid: pid} = state) do
    emit_telemetry([:connection, :down], %{
      client_id: state.client_id,
      producer_index: state.producer_index,
      reason: reason
    })

    {:stop, {:emqtt_exit, reason}, state}
  end

  # emqtt sends {:disconnected, reason_code, props} to the owner when it stays
  # alive across reconnects (i.e. config :reconnect is set). In that mode, the
  # emqtt process does not exit, so the :DOWN / :EXIT handlers above never fire
  # and we would otherwise miss the telemetry event for the connection drop.
  def handle_info({:disconnected, reason_code, _props}, %{connected?: true} = state) do
    emit_telemetry([:connection, :down], %{
      client_id: state.client_id,
      producer_index: state.producer_index,
      reason: reason_code
    })

    {:noreply, [], %{state | connected?: false}}
  end

  def handle_info({:disconnected, _reason_code, _props}, state) do
    {:noreply, [], state}
  end

  # Fired by emqtt after a successful (re)connect when reconnect is enabled.
  def handle_info({:connected, _props}, %{connected?: false} = state) do
    emit_telemetry([:connection, :up], %{
      client_id: state.client_id,
      producer_index: state.producer_index
    })

    {:noreply, [], %{state | connected?: true}}
  end

  def handle_info({:connected, _props}, state) do
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
  def terminate(reason, state) do
    if state.emqtt_pid && Process.alive?(state.emqtt_pid) do
      Process.demonitor(state.emqtt_ref, [:flush])
      Connection.disconnect(state.emqtt_pid)
    end

    if state.ack_ref, do: :persistent_term.erase(state.ack_ref)

    emit_telemetry([:producer, :terminate], %{
      broadway_name: state.broadway_name,
      producer_index: state.producer_index,
      client_id: state.client_id,
      reason: reason
    })

    :ok
  end

  defp build_broadway_message(mqtt_msg, state) do
    {message_handler, handler_opts} = get_message_handler(state.message_handler)
    ack_ref = state.ack_ref

    case apply(message_handler, :handle_message, [mqtt_msg, ack_ref, handler_opts]) do
      %Broadway.Message{} = msg ->
        ack_data = Acknowledger.build_ack_data(mqtt_msg, state.emqtt_pid)
        %{msg | acknowledger: {Acknowledger, ack_ref, ack_data}}

      other ->
        raise ArgumentError,
              "#{inspect(message_handler)}.handle_message/3 must return %Broadway.Message{}, " <>
                "got: #{inspect(other)}"
    end
  end

  defp get_message_handler({module, opts}), do: {module, opts}
  defp get_message_handler(module) when is_atom(module), do: {module, []}

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

  # When using MQTT v5, set Receive-Maximum in the CONNECT properties so the broker
  # enforces subscriber-side flow control. Without this, the broker sends messages
  # as fast as it can regardless of how many are unACKed by the subscriber.
  defp maybe_set_receive_maximum(config, max_inflight) do
    if Keyword.get(config, :proto_ver) == :v5 do
      existing_props = Keyword.get(config, :properties, %{})
      updated_props = Map.put_new(existing_props, :"Receive-Maximum", max_inflight)
      Keyword.put(config, :properties, updated_props)
    else
      config
    end
  end

  defp emit_telemetry(event, metadata, measurements \\ %{}) do
    :telemetry.execute(
      [:off_broadway_emqtt | event],
      Map.put(measurements, :time, System.system_time()),
      metadata
    )
  end
end
