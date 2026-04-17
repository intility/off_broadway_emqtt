defmodule OffBroadway.EMQTT.MessageHandler do
  @moduledoc """
  Behaviour for handling messages received from the MQTT broker.

  Custom message handlers can transform MQTT messages into Broadway messages.
  The default implementation extracts the payload as data and remaining fields as metadata.
  """

  @type message() :: map()
  @type ack_ref() :: any()

  @callback handle_message(message :: message(), ack_ref :: ack_ref(), opts :: keyword()) ::
              Broadway.Message.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def handle_message(message, ack_ref, opts),
        do: unquote(__MODULE__).handle_message(message, ack_ref, opts)

      defoverridable handle_message: 3
    end
  end

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
