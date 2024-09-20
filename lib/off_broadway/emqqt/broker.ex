defmodule OffBroadway.EMQTT.Broker do
  use GenServer
  require Logger

  def start_link(opts) do
    client_id = get_in(opts, [:config, :clientid])
    GenServer.start_link(__MODULE__, opts, name: :"#{__MODULE__}-#{client_id}")
  end

  @impl true
  def init(args) do
    with {:ok, config} <- Keyword.fetch(args, :config),
         {:ok, topics} <- Keyword.fetch(args, :topics),
         {:ok, client_id} <- Keyword.fetch(config, :clientid),
         {:ok, buffer_size} <- Keyword.fetch(args, :buffer_size),
         {:ok, buffer_overflow} <- Keyword.fetch(args, :buffer_overflow_strategy),
         {:ok, _message_handler} <- Keyword.fetch(args, :message_handler),
         {:ok, emqtt} <- :emqtt.start_link(config),
         {:ok, _props} <- :emqtt.connect(emqtt) do
      Process.flag(:trap_exit, true)

      {:ok,
       %{
         client_id: client_id,
         buffer_size: buffer_size,
         buffer_overflow: buffer_overflow,
         ets_table: String.to_existing_atom(client_id),
         emqtt: emqtt,
         emqtt_ref: Process.monitor(emqtt),
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

    {:noreply, state, {:continue, :subscribe_to_topics}}
  end

  def handle_continue(:subscribe_to_topics, state) do
    subscriptions =
      Enum.map(state.topics, &subscribe(state.emqtt, &1))
      |> Enum.map(fn {:ok, %{via: port}, qos} -> {port, qos} end)

    {:noreply, %{state | topic_subscriptions: subscriptions}}
  end

  @impl true
  def handle_info({:publish, message}, state) do
    case {:ets.info(state.ets_table, :size), state.buffer_overflow} do
      {count, :reject} when count >= state.buffer_sizer ->
        Logger.warning("MQTT Broker buffer for client id #{state.client_id} is full, rejecting message")
        measure_buffer_event(state.client_id, message.topic, count, :reject_message)
        {:noreply, [], state}

      {count, :drop_head} when count >= state.buffer_size ->
        Logger.warning("MQTT Broker buffer for client id #{state.client_id} is full, dropping head")
        measure_buffer_event(state.client_id, message.topic, count, :drop_message)
        # :ets.delete_element(state.ets_table, :head)
        # :ets.insert_new(state.ets_table, {:tail, message})
        {:noreply, [], state}

      {count, _} ->
        measure_buffer_event(state.client_id, message.topic, count, :accept_message)
        :ets.insert(state.ets_table, {:erlang.phash2({state.client_id, message}), message})
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Process.demonitor(state.emqtt_ref)
    :ets.delete(state.ets_table)
  end

  @spec subscribe(pid(), {String.t(), term()}) :: {:ok, {:via, port()}, [pos_integer()]} | {:error, term()}
  defp subscribe(emqtt, topic) when is_tuple(topic), do: :emqtt.subscribe(emqtt, topic)

  defp measure_buffer_event(client_id, topic, buffer_size, event_type) do
    :telemetry.execute(
      [:off_broadway_emqtt, :buffer, event_type],
      %{time: System.system_time(), count: 1},
      %{client_id: client_id, topic: topic, buffer_size: buffer_size}
    )
  end

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

  @spec stream_from_buffer(atom()) :: Enumerable.t()
  def stream_from_buffer(ets_table) do
    Stream.resource(
      fn -> [] end,
      fn acc ->
        case acc do
          [] -> receive_first(ets_table, acc)
          acc -> receive_next(ets_table, acc)
        end
      end,
      fn keys -> Enum.each(keys, &:ets.delete(ets_table, &1)) end
    )
  end

  defp receive_first(ets_table, acc) do
    with key when is_integer(key) <- :ets.first(ets_table),
         spec <- [{{:"$1", :"$2"}, [{:==, :"$1", key}], [:"$2"]}],
         message <- :ets.select(ets_table, spec) do
      {message, [key]}
    else
      _ -> {:halt, acc}
    end
  end

  defp receive_next(ets_table, acc) do
    with key when is_integer(key) <- :ets.next(ets_table, acc),
         spec <- [{{:"$1", :"$2"}, [{:==, :"$1", key}], [:"$2"]}],
         message <- :ets.select(ets_table, spec) do
      {message, [key]}
    else
      _ -> {:halt, acc}
    end
  end
end
