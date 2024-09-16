defmodule OffBroadway.EMQTT.MessageHandler do
  @moduledoc """
  Behaviour for handling messages received from the MQTT broker.
  The default implementation is a `GenServer` that keeps messages received from the broker
  in a queue. Whenever the producer asks for messages, the handler will dequeue them from the queue
  and return them to the producer.

  Custom message handlers can be implemented by defining a module that implements this behaviour.
  """

  @type message() :: term()
  @type reason_code() :: term()
  @type broadway() :: atom() | {:via, module(), term()}

  @doc """
  Messages received from the MQTT broker are passed to this function.
  """
  @callback handle_message(message :: message(), broadway :: broadway(), opts :: keyword()) :: any() | mfa()

  @doc """
  `PUBREL` messages received from the MQTT broker are passed to this function.
  """
  @callback handle_pubrel(pubrel :: map()) :: any() | mfa()

  @doc """
  Callback invoked after a successful connection to the MQTT broker.
  """
  @callback handle_connect(properties :: term()) :: any() | mfa()

  @doc """
  Callback invoked after a disconnect from the MQTT broker.
  """
  @callback handle_disconnect({reason :: reason_code(), properties :: term()} | atom()) ::
              any() | mfa()

  @doc """
  Callback invoked from the producer to ask for messages to be processed.
  """
  @callback receive_messages(demand :: non_neg_integer(), opts :: keyword()) :: [Broadway.Message.t()]

  defmacro __using__(_opts) do
    quote do
      @behaviour GenServer
      @behaviour OffBroadway.EMQTT.MessageHandler

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_connect(properties),
        do: OffBroadway.EMQTT.MessageHandler.handle_connect(properties)

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_disconnect(reason),
        do: OffBroadway.EMQTT.MessageHandler.handle_disconnect(properties)

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_message(message, broadway, opts),
        do: OffBroadway.EMQTT.MessageHandler.handle_message(properties, broadway, opts)

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_pubrel(pubrel), do: OffBroadway.EMQTT.MessageHandler.handle_pubrel(properties)

      @impl OffBroadway.EMQTT.MessageHandler
      def receive_messages(demand, opts), do: OffBroadway.EMQTT.MessageHandler.reveive_messages(demand, opts)

      defoverridable handle_connect: 1
      defoverridable handle_disconnect: 1
      defoverridable handle_message: 2
      defoverridable handle_pubrel: 1
      defoverridable receive_messages: 2
    end
  end

  use GenServer
  require Logger
  alias OffBroadway.EMQTT.Producer

  @behaviour Broadway.Acknowledger

  def start_link(opts) do
    with {_, client_opts} <- get_in(opts, [:producer, :module]),
         {:ok, broadway} <- Keyword.fetch(opts, :name),
         {:ok, name} <- Keyword.fetch(client_opts, :message_handler_name) do
      GenServer.start_link(__MODULE__, client_opts ++ [broadway: broadway], name: name)
    end
  end

  @impl GenServer
  def init(params) do
    with {:ok, broadway} <- Keyword.fetch(params, :broadway),
         {:ok, buffer_size} <- Keyword.fetch(params, :buffer_size),
         {:ok, overflow_strategy} <- Keyword.fetch(params, :buffer_overflow_strategy),
         client_id <- get_in(params, [:config, :clientid]),
         counters <- :counters.new(2, [:atomics]),
         :ok <- :counters.put(counters, 2, buffer_size) do
      {:ok,
       %{
         queue: :queue.new(),
         broadway: broadway,
         counters: counters,
         client_id: client_id,
         ets_table: nil,
         buffer_size: buffer_size,
         overflow_strategy: overflow_strategy
       }, {:continue, :create_ets_table}}
    end
  end

  # Use a named ETS table to store messages received from the MQTT broker.
  # We use a duplicate_bag because when working with potentially large number
  # of messages, the performance penalty of deduplication is huge.
  # Additionally, the table has to be public to allow the `:emqtt` process
  # to write to it.
  @impl GenServer
  def handle_continue(:create_ets_table, state) do
    {:noreply, %{state | ets_table: :ets.new(String.to_atom(state.client_id), [:ordered_set, :named_table, :public])}}
  end

  @impl GenServer
  def handle_call({:dequeue, demand}, _from, state) do
    case dequeue(state.queue, demand) do
      {:error, :empty, queue} ->
        IO.inspect("Queue is empty")
        maybe_resume_mqtt_server(state.client_id, state.counters)
        {:reply, [], %{state | queue: queue}}

      {:ok, messages, queue} ->
        :counters.sub(state.counters, 1, length(messages))
        maybe_resume_mqtt_server(state.client_id, state.counters)
        IO.inspect("Dequeued #{length(messages)} messages")
        # Broadway.push_messages(state.broadway, messages)
        {:reply, messages, %{state | queue: queue}}
    end
  end

  @impl GenServer
  def handle_cast({:enqueue, message, ack_ref}, state) do
    case {:counters.get(state.counters, 1), state.overflow_strategy} do
      {count, :reject} when count >= state.buffer_size ->
        Logger.info("Buffer for client #{state.client_id} is full, rejecting message")
        {:noreply, state}

      {count, :drop_head} when count >= state.buffer_size ->
        Logger.info("Buffer for client #{state.client_id} is full, dropping head message")
        new_queue = enqueue(:queue.drop(state.queue), build_message(message, ack_ref))
        {:noreply, %{state | queue: new_queue}}

      {_, _} ->
        new_queue = enqueue(state.queue, build_message(message, ack_ref))
        :counters.add(state.counters, 1, 1)
        maybe_pause_mqtt_server(state.client_id, state.counters)
        {:noreply, %{state | queue: new_queue}}
    end
  end

  defp maybe_pause_mqtt_server(client_id, counters) do
    with true <- buffer_fill_pst(counters) > 80.0,
         process_name <- Producer.emqtt_process_name(to_string(client_id)),
         emqtt_server <- Process.whereis(process_name) do
      IO.inspect(:counters.get(counters, 1))
      Logger.info("Pausing :emqtt server for #(inspect(client_id))")
      :emqtt.pause(emqtt_server)
    else
      false -> :ok
    end
  end

  defp maybe_resume_mqtt_server(client_id, counters) do
    with true <- buffer_fill_pst(counters) < 80.0,
         process_name <- Producer.emqtt_process_name(to_string(client_id)),
         emqtt_server <- Process.whereis(process_name) do
      Logger.info("Resuming :emqtt server for #(inspect(client_id))")
      :emqtt.resume(emqtt_server)
    else
      false -> :ok
    end
  end

  @impl GenServer
  def terminate(_, state),
    do: :ets.delete_all_objects(state.ets_table)

  def handle_connect(_properties), do: Logger.info("Connected to MQTT broker")
  def handle_disconnect(_reason), do: Logger.info("Disconnected from MQTT broker")
  def handle_pubrel(_pubrel), do: Logger.debug("PUBREL received from MQTT broker")

  # def handle_message(message, _broadway, opts) do
  #   with {:ok, counter} <- Keyword.fetch(opts, :buffer_counter),
  #        {:ok, buffer_size} <- Keyword.fetch(opts, :buffer_size),
  #        {:ok, strategy} <- Keyword.fetch(opts, :buffer_overflow_strategy),
  #        {:ok, config} <- Keyword.fetch(opts, :config),
  #        {:ok, client_id} <- Keyword.fetch(config, :clientid),
  #        ets_table <- String.to_existing_atom(client_id) do
  #     case {:counters.get(counter, 1), strategy} do
  #       {count, :reject} when count >= buffer_size ->
  #         :counters.add(counter, 2, 1)
  #         Logger.info("Buffer for client #{client_id} is full, rejecting message")

  #       {count, :drop_head} when count >= buffer_size ->
  #         # TODO :implement
  #         :counters.add(counter, 2, 1)
  #         Logger.info("Buffer for client #{client_id} is full, dropping head message")

  #       {_, _} ->
  #         :ets.insert(ets_table, {:erlang.phash2(message), message})
  #         :counters.add(counter, 1, 1)
  #     end
  #   end
  # end

  # def receive_messages(demand, opts) do
  #   IO.inspect(opts)
  #   with {:ok, broadway} <- Keyword.fetch(opts, :broadway),
  #        {:ok, client_id} <- Keyword.fetch(opts, :client_id) do
  #     receive_from_ets_lazy(client_id)
  #     |> Stream.take(demand)
  #     |> Stream.map(&build_message(&1, broadway))
  #     |> Enum.into([])
  #     |> IO.inspect(label: "Received messages from ETS")
  #   end
  # end

  # defp receive_from_ets_lazy(ets_table) do
  #   Stream.resource(
  #     fn -> [] end,
  #     fn acc ->
  #       case acc do
  #         [] -> receive_first(ets_table, acc)
  #         acc -> receive_next(ets_table, acc)
  #       end
  #     end,
  #     fn _ -> :ok end
  #   )
  # end

  # defp receive_first(ets_table, acc) do
  #   with key when is_integer(key) <- :ets.first(ets_table),
  #        spec <- [{{:"$1", :"$2"}, [{:==, :"$1", key}], [:"$2"]}],
  #        message <- :ets.select(ets_table, spec) do
  #     :ets.delete(ets_table, key)
  #     {message, [key]}
  #   else
  #     _ -> {:halt, acc}
  #   end
  # end

  # defp receive_next(ets_table, acc) do
  #   with key when is_integer(key) <- :ets.next(ets_table, acc),
  #        spec <- [{{:"$1", :"$2"}, [{:==, :"$1", key}], [:"$2"]}],
  #        message <- :ets.select(ets_table, spec) do
  #     :ets.delete(ets_table, key)
  #     {message, [key]}
  #   else
  #     _ -> {:halt, acc}
  #   end
  # end

  # def handle_message(message, broadway, opts) do
  #   with client_id <- get_in(opts, [:config, :clientid]),
  #        mqtt_name <- Producer.emqtt_process_name(client_id),
  #        handler_name <- Producer.message_handler_process_name(client_id),
  #        mqtt when is_pid(mqtt) <- Process.whereis(mqtt_name),
  #        handler when is_pid(handler) <- Process.whereis(handler_name) do
  #     IO.inspect(opts)
  #     IO.inspect(mqtt, label: "MQTT server")
  #     IO.inspect(handler, label: "Message handler")
  #   end
  # end

  def handle_message(message, broadway, opts) do
    with {:ok, config} <- Keyword.fetch(opts, :config),
         handler <- OffBroadway.EMQTT.Producer.message_handler_process_name(config[:clientid]),
         pid when is_pid(pid) <- GenServer.whereis(handler) do
      IO.inspect("Forwarding message to #{handler}")
      GenServer.cast(pid, {:enqueue, message, broadway})
    else
      nil ->
        Logger.error("Failed to enqueue message: handler not found, shutting down")
        Broadway.stop(broadway, :shutdown)

      reason ->
        Logger.error("Failed to enqueue message: #{inspect(reason)}")
    end
  end

  def receive_messages(demand, opts) do
    IO.inspect(opts)
    []
  end

  @impl Broadway.Acknowledger
  def ack(ack_ref, successful, failed) do
    ack_options = :persistent_term.get(ack_ref)

    # TODO Respect `emqtt` ack options
    Stream.concat(
      Stream.filter(successful, &ack?(&1, ack_options, :on_success)),
      Stream.filter(failed, &ack?(&1, ack_options, :on_failure))
    )
    |> Stream.each(&ack_message(&1, ack_options))
    |> Stream.run()
  end

  defp ack?(message, ack_options, option) do
    {_, _, msg_ack_options} = message.acknowledger
    (msg_ack_options[option] || Map.fetch!(ack_options, option)) == :ack
  end

  def ack_message(message, _ack_options) do
    :telemetry.execute(
      [:off_broadway_emqtt, :receive_message, :ack],
      %{time: System.system_time(), count: 1},
      %{topic: message.data.topic, receipt: extract_message_receipt(message)}
    )
  end

  defp enqueue(queue, %Broadway.Message{} = message), do: :queue.in(message, queue)

  # We could use :queue.split/2 here, but it is O(n). This implementation is
  # also O(n), where n is the number of messages to dequeue. Maybe :queue.split/2 is
  # better after all?
  defp dequeue(queue, n), do: dequeue(queue, n, [])
  defp dequeue(queue, 0, acc), do: {:ok, Enum.reverse(acc), queue}

  defp dequeue(queue, n, acc) when n > 0 do
    case :queue.out(queue) do
      {:empty, queue} -> {:error, :empty, queue}
      {{:value, item}, queue} -> dequeue(queue, n - 1, [item | acc])
    end
  end

  defp buffer_fill_pst(counters),
    do: ceil(:counters.get(counters, 1) / :counters.get(counters, 2) * 100)

  defp build_message(message, ack_ref) do
    acknowledger = build_acknowledger(message, ack_ref)
    %Broadway.Message{data: message, acknowledger: acknowledger}
  end

  defp build_acknowledger(message, ack_ref) do
    receipt = Map.take(message, [:packet_id, :qos, :retain, :topic])
    {__MODULE__, ack_ref, %{receipt: receipt}}
  end

  defp extract_message_receipt(%{acknowledger: {_, _, %{receipt: receipt}}}), do: receipt
end
