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
      use GenServer
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
      def receive_message(demand, opts), do: OffBroadway.EMQTT.MessageHandler.reveive_message(demand, opts)

      defoverridable handle_connect: 1
      defoverridable handle_disconnect: 1
      defoverridable handle_message: 2
      defoverridable handle_pubrel: 1
      defoverridable receive_message: 2
    end
  end

  use GenServer
  require Logger
  @behaviour Broadway.Acknowledger

  def start_link(opts) do
    with {_, client_opts} <- get_in(opts, [:producer, :module]),
         {:ok, name} <- Keyword.fetch(client_opts, :message_handler_name) do
      GenServer.start_link(__MODULE__, client_opts, name: name)
    end
  end

  @impl GenServer
  def init(params) do
    with {:ok, buffer_size} <- Keyword.fetch(params, :buffer_size),
         {:ok, overflow_strategy} <- Keyword.fetch(params, :buffer_overflow_strategy),
         client_id <- get_in(params, [:config, :clientid]),
         counters <- :counters.new(2, [:atomics]),
         :ok <- :counters.put(counters, 2, buffer_size) do
      {:ok,
       %{
         queue: :queue.new(),
         counters: counters,
         client_id: client_id,
         buffer_size: buffer_size,
         overflow_strategy: overflow_strategy
       }}
    end
  end

  @impl GenServer
  def handle_call({:dequeue, demand}, _from, state) do
    case dequeue(state.queue, demand) do
      {:error, :empty, queue} ->
        {:reply, [], %{state | queue: queue}}

      {:ok, messages, queue} ->
        :counters.sub(state.counters, 1, length(messages))
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
        {:noreply, %{state | queue: new_queue}}
    end
  end

  def handle_connect(_properties), do: Logger.info("Connected to MQTT broker")
  def handle_disconnect(_reason), do: Logger.info("Disconnected from MQTT broker")
  def handle_pubrel(_pubrel), do: Logger.debug("PUBREL received from MQTT broker")

  def handle_message(message, ack_ref, opts) do
    with {:ok, config} <- Keyword.fetch(opts, :config),
         handler <- OffBroadway.EMQTT.Producer.message_handler_process_name(config[:clientid]),
         pid when is_pid(pid) <- GenServer.whereis(handler) do
      GenServer.cast(pid, {:enqueue, message, ack_ref})
    else
      reason ->
        Logger.error("Failed to enqueue message: #{inspect(reason)}")
    end
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
