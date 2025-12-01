defmodule OffBroadway.EMQTT.MessageHandler do
  @moduledoc """
  Behaviour for handling messages received from the MQTT broker.

  Custom message handlers can transform MQTT messages into Broadway messages.
  The default implementation extracts the payload as data and remaining fields as metadata.
  """

  @type message() :: map()
  @type broadway() :: atom() | {:via, module(), term()}

  @callback handle_message(message :: message(), broadway :: broadway(), opts :: keyword()) ::
              Broadway.Message.t()

  @callback handle_pubrel(pubrel :: map()) :: any()

  @callback handle_connect(properties :: term()) :: any()

  @callback handle_disconnect({reason :: term(), properties :: term()} | atom()) :: any()

  defmacro __using__(_opts) do
    quote do
      @behaviour OffBroadway.EMQTT.MessageHandler

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_connect(properties),
        do: OffBroadway.EMQTT.MessageHandler.handle_connect(properties)

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_disconnect(reason),
        do: OffBroadway.EMQTT.MessageHandler.handle_disconnect(reason)

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_message(message, broadway, opts),
        do: OffBroadway.EMQTT.MessageHandler.handle_message(message, broadway, opts)

      @impl OffBroadway.EMQTT.MessageHandler
      def handle_pubrel(pubrel),
        do: OffBroadway.EMQTT.MessageHandler.handle_pubrel(pubrel)

      defoverridable handle_connect: 1,
                     handle_disconnect: 1,
                     handle_message: 3,
                     handle_pubrel: 1
    end
  end

  require Logger

  def handle_connect(_properties), do: Logger.debug("Connected to MQTT broker")
  def handle_disconnect(_reason), do: Logger.debug("Disconnected from MQTT broker")
  def handle_pubrel(_pubrel), do: Logger.debug("PUBREL received")

  def handle_message(message, ack_ref, _opts) do
    message = Map.drop(message, [:via, :client_pid])
    {payload, metadata} = Map.pop(message, :payload)

    %Broadway.Message{
      data: payload,
      metadata: metadata,
      acknowledger: {OffBroadway.EMQTT.Acknowledger, ack_ref, %{}}
    }
  end
end
