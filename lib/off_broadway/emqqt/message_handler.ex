defmodule OffBroadway.EMQTT.MessageHandler do
  @moduledoc """
  Behaviour for handling messages received from the MQTT broker.
  Custom message handlers can be implemented by defining a module that implements this behaviour.
  """

  @type message() :: term()
  @type reason_code() :: term()
  @type broadway() :: atom() | {:via, module(), term()}

  @doc """
  Messages are passed to this function after the producer has received them from the MQTT broker.
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
      def handle_message(message, broadway, opts),
        do: OffBroadway.EMQTT.MessageHandler.handle_message(properties, broadway, opts)

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_pubrel(pubrel), do: OffBroadway.EMQTT.MessageHandler.handle_pubrel(properties)

      defoverridable handle_connect: 1
      defoverridable handle_disconnect: 1
      defoverridable handle_message: 2
      defoverridable handle_pubrel: 1
    end
  end

  require Logger
  @behaviour Broadway.Acknowledger

  def handle_connect(_properties), do: Logger.info("Connected to MQTT broker")
  def handle_disconnect(_reason), do: Logger.info("Disconnected from MQTT broker")
  def handle_pubrel(_pubrel), do: Logger.debug("PUBREL received from MQTT broker")

  def handle_message(message, broadway, _opts),
    do: build_message(message, broadway)

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
