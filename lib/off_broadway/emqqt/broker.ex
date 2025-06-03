defmodule OffBroadway.EMQTT.Broker do
  @moduledoc """
  The `OffBroadway.EMQTT.Broker` is started as part of the Broadway pipeline
  supervision tree and is responsible for managing the connection to the MQTT
  broker and cache incoming messages until the producer is ready to consume them.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    name = get_in(opts, [:config, :name])
    GenServer.start_link(__MODULE__, opts, name: :"#{__MODULE__}-#{name}")
  end

  @impl true
  def init(args) do
    with {:ok, config} <- Keyword.fetch(args, :config),
         {:ok, topics} <- Keyword.fetch(args, :topics),
         {:ok, client_id} <- Keyword.fetch(config, :clientid),
         {:ok, buffer_size} <- Keyword.fetch(args, :buffer_size),
         {:ok, buffer_log_dir} <- Keyword.fetch(args, :buffer_log_dir),
         {:ok, buffer_overflow} <- Keyword.fetch(args, :buffer_overflow_strategy),
         {:ok, buffer_durability} <- Keyword.fetch(args, :buffer_durability),
         {:ok, _message_handler} <- Keyword.fetch(args, :message_handler) do
      Process.flag(:trap_exit, true)

      {:ok,
       %{
         client_id: client_id,
         buffer_size: buffer_size,
         buffer_log: nil,
         buffer_log_dir: buffer_log_dir,
         buffer_overflow: buffer_overflow,
         buffer_durability: buffer_durability,
         buffer_threshold: {20.0, 70.0},
         buffer_threshold_ref: nil,
         ets_table: String.to_existing_atom(client_id),
         emqtt: nil,
         emqtt_ref: nil,
         emqtt_config: config,
         topics: topics,
         topic_subscriptions: []
       }, {:continue, :create_ets_table}}
    else
      _ -> {:stop, :error}
    end
  end

  @impl true
  def handle_continue(:create_ets_table, state) do
    # Create a public ETS table to act as message buffer. It needs to be public
    # because the Producer process will read directly from it to avoid copying
    # the content across processes.
    :ets.new(state.ets_table, [
      :ordered_set,
      :named_table,
      :public,
      {:read_concurrency, true}
    ])

    # If the buffer durability is set to :durable, we wrap the ETS table in a disk log.
    case state.buffer_durability do
      :durable -> {:noreply, state, {:continue, :open_buffer_log}}
      :transient -> {:noreply, state, {:continue, :connect_to_broker}}
    end
  end

  def handle_continue(:open_buffer_log, state) do
    case :disk_log.open(
           name: state.ets_table,
           file: buffer_log_file(state.buffer_log_dir, state.ets_table),
           format: :internal,
           repair: true,
           mode: :read_write
         ) do
      {:ok, buffer_log} ->
        {:noreply, %{state | buffer_log: buffer_log}, {:continue, :replay_buffer_log}}

      {:repaired, buffer_log, {:recovered, n_terms}, {:badbytes, n_bytes}} ->
        Logger.warning(
          "Repaired buffer log for client id #{state.client_id}, recovered #{n_terms} terms, bad bytes: #{n_bytes}"
        )

        {:noreply, %{state | buffer_log: buffer_log}, {:continue, :replay_buffer_log}}

      {:error, reason} ->
        Logger.error("Failed to open buffer log for client id #{state.client_id}: #{inspect(reason)}")
        {:stop, :error, state}
    end
  end

  def handle_continue(:replay_buffer_log, %{ets_table: ets_table, buffer_log: buffer_log} = state) do
    :telemetry.span(
      [:off_broadway_emqtt, :replay_buffer],
      %{client_id: state.client_id, buffer_size: buffer_log_info(buffer_log).items},
      fn ->
        stream_from_buffer_log(buffer_log)
        |> Stream.chunk_every(100)
        |> Stream.each(&:ets.insert(ets_table, &1))
        |> Stream.run()

        {:disk_log.truncate(buffer_log), %{client_id: state.client_id, buffer_size: buffer_log_info(buffer_log).items}}
      end
    )

    {:noreply, state, {:continue, :connect_to_broker}}
  end

  def handle_continue(:connect_to_broker, state) do
    with {:ok, pid} <- :emqtt.start_link(state.emqtt_config),
         {:ok, _props} <- :emqtt.connect(pid) do
      {:noreply, %{state | emqtt: pid, emqtt_ref: Process.monitor(pid)}, {:continue, :subscribe_to_topics}}
    else
      {:error, reason} ->
        Logger.error("Failed to connect to MQTT broker: #{inspect(reason)}")
        {:stop, :error, state}
    end
  end

  def handle_continue(:subscribe_to_topics, state) do
    subscriptions =
      Enum.map(state.topics, &subscribe(state.emqtt, &1))
      |> Enum.map(fn
        {:ok, %{via: port}, qos} -> {port, qos}
        {:error, reason} -> Logger.error("Subscribing to topic failed with reason #{inspect(reason)}")
      end)

    # Start a timer to check the buffer fill percentage and pause/resume the EMQTT client
    ref =
      :timer.apply_repeatedly(500, __MODULE__, :check_buffer_threshold, [
        state.buffer_size,
        state.buffer_threshold,
        state.ets_table,
        state.emqtt
      ])

    {:noreply, %{state | topic_subscriptions: subscriptions, buffer_threshold_ref: ref}}
  end

  @impl true
  def handle_cast(:stop_emqtt, state) do
    if Process.alive?(state.emqtt), do: :emqtt.stop(state.emqtt)
    {:noreply, state}
  end

  @impl true
  def handle_info({:publish, message}, state) do
    # FIXME: This floods the output with log messages when the buffer is full.
    case {:ets.info(state.ets_table, :size), state.buffer_overflow} do
      {count, :reject} when count >= state.buffer_size ->
        Logger.warning("MQTT Broker buffer for client id #{state.client_id} is full, rejecting message")
        execute_telemetry_event(state.client_id, message.topic, count, :reject_message)

      {count, :drop_head} when count >= state.buffer_size ->
        Logger.warning("MQTT Broker buffer for client id #{state.client_id} is full, dropping head")

        key = :ets.first(state.ets_table)
        :ets.delete(state.ets_table, key)
        execute_telemetry_event(state.client_id, message.topic, count, :drop_message)
        write_to_buffer(state, {:erlang.phash2({state.client_id, message}), message})

      {_count, _} ->
        write_to_buffer(state, {:erlang.phash2({state.client_id, message}), message})
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, :normal}, state) when ref == state.emqtt_ref, do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _reason}, state) when ref == state.emqtt_ref do
    {:ok, pid} = :emqtt.start_link(state.emqtt_config)
    {:ok, _props} = :emqtt.connect(pid)
    {:noreply, %{state | emqtt: pid, emqtt_ref: Process.monitor(pid)}, {:continue, :subscribe_to_topics}}
  end

  def handle_info({:EXIT, _, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_reference(state.emqtt_ref), do: Process.demonitor(state.emqtt_ref)
    :ets.delete(state.ets_table)

    with :durable <- state.buffer_durability,
         buffer_log when not is_nil(buffer_log) <- state.buffer_log do
      :telemetry.span(
        [:off_broadway_emqtt, :sync_buffer],
        %{client_id: state.client_id, buffer_size: buffer_log_info(buffer_log).items},
        fn ->
          :disk_log.sync(buffer_log)
          {:disk_log.close(buffer_log), %{client_id: state.client_id, buffer_size: buffer_log_info(buffer_log).items}}
        end
      )
    end
  end

  @spec stop_emqtt(pid()) :: :ok
  def stop_emqtt(pid), do: GenServer.cast(pid, :stop_emqtt)

  @spec check_buffer_threshold(non_neg_integer(), {non_neg_integer(), non_neg_integer()}, atom(), pid()) :: :ok
  def check_buffer_threshold(buffer_size, {min_threshold, max_threshold}, ets_table, emqtt) do
    case buffer_fill_percentage(buffer_size, :ets.info(ets_table, :size)) do
      fill_percentage when fill_percentage >= max_threshold ->
        Logger.debug(
          "Buffer fill percentage for client id #{:emqtt.info(emqtt)[:clientid]} is " <>
            "#{:erlang.float_to_binary(fill_percentage, decimals: 2)}%, pausing EMQTT client"
        )

        :ok = :emqtt.pause(emqtt)

      fill_percentage when fill_percentage < min_threshold ->
        :ok = :emqtt.resume(emqtt)

      _fill_percentage ->
        :ok
    end
  end

  @spec stream_from_buffer_log(atom()) :: Enumerable.t()
  def stream_from_buffer_log(buffer_log) do
    Stream.resource(
      fn -> :start end,
      fn
        :eof -> {:halt, :eof}
        cont -> receive_next_log(buffer_log, cont)
      end,
      fn _ -> :ok end
    )
  end

  @spec receive_next_log(atom() | binary(), any()) :: {list(), any()} | {:halt, :eof}
  defp receive_next_log(_buffer_log, :eof), do: {:halt, :eof}

  defp receive_next_log(buffer_log, cont) do
    case :disk_log.chunk(buffer_log, cont) do
      {{:continuation, _, _, _} = next_cont, chunk} ->
        {chunk, next_cont}

      :eof ->
        {[], :eof}

      {:error, reason} ->
        Logger.error("Error reading from buffer log: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec stream_from_buffer(atom()) :: Enumerable.t()
  def stream_from_buffer(ets_table) do
    Stream.resource(
      fn -> :ets.first(ets_table) end,
      fn
        :"$end_of_table" -> {:halt, :"$end_of_table"}
        key -> receive_next_buffer(ets_table, key)
      end,
      fn _ -> :ok end
    )
  end

  @spec receive_next_buffer(atom(), any()) :: {list(), any()}
  defp receive_next_buffer(_ets_table, :"$end_of_table"), do: {:halt, :"$end_of_table"}

  defp receive_next_buffer(ets_table, key) do
    case :ets.lookup(ets_table, key) do
      [] ->
        {:halt, :"$end_of_table"}

      [{key, value}] ->
        :ets.delete(ets_table, key)

        # NOTE: We name the disk log after the ETS table to ensure consistency.
        # Whenever we read data from the buffer, truncate the disk log to avoid keeping unnecessary data.
        case :disk_log.info(ets_table) do
          {:error, :no_such_log} -> :ok
          _ -> :disk_log.truncate(ets_table)
        end

        next_key = :ets.next(ets_table, key)
        {[value], next_key}
    end
  end

  @spec subscribe(pid(), {String.t(), term()}) :: {:ok, {:via, port()}, [pos_integer()]} | {:error, term()}
  defp subscribe(emqtt, topic) when is_tuple(topic), do: :emqtt.subscribe(emqtt, topic)

  @spec execute_telemetry_event(String.t(), String.t(), non_neg_integer(), atom()) :: :ok
  defp execute_telemetry_event(client_id, topic, buffer_size, event_type) do
    :telemetry.execute(
      [:off_broadway_emqtt, :buffer, event_type],
      %{time: System.system_time(), count: 1},
      %{client_id: client_id, topic: topic, buffer_size: buffer_size}
    )
  end

  @spec write_to_buffer(map(), {atom(), any()}) :: :ok
  defp write_to_buffer(%{buffer_durability: :durable, buffer_log: buffer_log} = state, {hash, message})
       when is_atom(buffer_log) do
    :ok = :disk_log.log(buffer_log, {hash, message})
    true = :ets.insert(state.ets_table, {hash, message})

    info = buffer_log_info(buffer_log)
    execute_telemetry_event(state.client_id, message.topic, info.items, :log_write)
    execute_telemetry_event(state.client_id, message.topic, :ets.info(state.ets_table, :size), :accept_message)
  end

  defp write_to_buffer(state, {hash, message}) do
    true = :ets.insert(state.ets_table, {hash, message})
    execute_telemetry_event(state.client_id, message.topic, :ets.info(state.ets_table, :size), :accept_message)
  end

  @spec buffer_log_info(atom()) :: map()
  defp buffer_log_info(buffer_log), do: Enum.into(:disk_log.info(buffer_log), %{})

  @spec buffer_log_file(binary() | (0 -> binary()), String.t()) :: charlist()
  defp buffer_log_file(dir, name) when is_binary(dir) do
    Path.join(dir, "#{name}.log")
    |> String.to_charlist()
  end

  defp buffer_log_file(dir, name) when is_function(dir, 0) do
    apply(dir, [])
    |> Path.join("#{name}.log")
    |> String.to_charlist()
  end

  @spec buffer_fill_percentage(non_neg_integer(), non_neg_integer()) :: float()
  defp buffer_fill_percentage(buffer_size, count), do: min(100.0, count * 100.0 / buffer_size)

  # @spec emqtt_message_handler(atom() | {atom(), keyword()}) :: map()
  # defp emqtt_message_handler(message_handler) do
  #   {message_handler, args} =
  #     case Producer.message_handler_module(message_handler) do
  #       {message_handler, args} -> {message_handler, args}
  #       message_handler -> {message_handler, []}
  #     end

  #   %{
  #     connected: {message_handler, :handle_connect, args},
  #     disconnected: {message_handler, :handle_disconnect, args},
  #     pubrel: {message_handler, :handle_pubrel, args}
  #   }
  # end
end
