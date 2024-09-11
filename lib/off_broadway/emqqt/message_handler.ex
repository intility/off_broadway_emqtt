defmodule OffBroadway.EMQTT.MessageHandler do
  @moduledoc """
  A custom message handler for the `:emqtt` producer can be used by
  implementing this behaviour.
  """

  @type message() :: term()
  @type reason_code() :: term()

  @callback handle_message(message :: message(), opts :: keyword()) :: any() | mfa()
  @callback handle_pubrel(pubrel :: map()) :: any() | mfa()
  @callback handle_connect(properties :: term()) :: any() | mfa()
  @callback handle_disconnect({reason :: reason_code(), properties :: term()} | atom()) ::
              any() | mfa()

  @behaviour Broadway.Acknowledger
  use GenServer

  defmacro __using__(_opts) do
    quote do
      @behaviour OffBroadway.EMQTT.MessageHandler

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_connect(properties),
        do: OffBroadway.EMQTT.MessageHandler.handle_connect(properties)

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_disconnect(reason),
        do: OffBroadway.EMQTT.MessageHandler.handle_disconnect(properties)

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_message(message, opts),
        do: OffBroadway.EMQTT.MessageHandler.handle_message(properties, opts)

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_pubrel(pubrel), do: OffBroadway.EMQTT.MessageHandler.handle_pubrel(properties)

      # @impl Broadway.Acknowledger
      # def ack(ack_ref, successful, failed), do: Broadway.Acknowledger.ack(ack_ref, successful, failed)

      defoverridable handle_connect: 1
      defoverridable handle_disconnect: 1
      defoverridable handle_message: 2
      defoverridable handle_pubrel: 1
    end
  end

  def start_link(opts) do
    with {_, client_opts} <- get_in(opts, [:producer, :module]),
         {:ok, name} <- Keyword.fetch(client_opts, :message_handler_name) do
      GenServer.start_link(__MODULE__, %{}, name: name)
    end
  end

  @impl GenServer
  def init(params) do
    {:ok, params}
  end

  @impl GenServer
  def handle_call({:demand, demand}, _from, state) do
    # TODO Dequeue messages
    IO.inspect("Receive demand #{demand}")
    {:reply, [1, 2, 3, 4], state}
  end

  def handle_connect(_properties) do
    IO.puts("Connected")
  end

  def handle_disconnect(_reason) do
    IO.puts("Disconnected")
  end

  def handle_message(message, opts) do
    {ack_ref, _opts} = Keyword.pop(opts, :ack_ref)
    # TODO Queue and push messages
    push_message(message, ack_ref)
  end

  def handle_pubrel(_pubrel) do
    IO.puts("Pubrel received")
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

  defp push_message(message, ack_ref) do
    acknowledger = build_acknowledger(message, ack_ref)
    Broadway.push_messages(ack_ref, [%Broadway.Message{data: message, acknowledger: acknowledger}])
  end

  defp build_acknowledger(message, ack_ref) do
    receipt = Map.take(message, [:packet_id, :qos, :retain, :topic])
    {__MODULE__, ack_ref, %{receipt: receipt}}
  end

  defp extract_message_receipt(%{acknowledger: {_, _, %{receipt: receipt}}}), do: receipt
end
