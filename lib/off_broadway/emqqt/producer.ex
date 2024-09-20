defmodule OffBroadway.EMQTT.Producer do
  @moduledoc """
  An MQTT producer based on [emqtt](https://github.com/emqx/emqtt) for Broadway.

  ## Producer options

  #{NimbleOptions.docs(OffBroadway.EMQTT.Options.definition())}

  ## Acknowledgements

  TBD

  ## Telemetry

  This library exposes the following telemetry events:

    * `[:off_broadway_emqtt, :receive_messages, :start]` - Dispatched before messages are received from
      the `ETS` buffer.

        * measurement: `%{time: System.monotonic_time}`
        * metadata: `%{client_id: string, demand: non_neg_integer}`


     * `[:off_broadway_emqtt, :receive_messages, :stop]` - Dispatched after messages have been
      received from the `ETS` buffer and "wrapped".

        * measurement: `%{time: native_time}`
        * metadata: `%{client_id: string, topics: [string], received: non_neg_integer, demand: non_neg_integer}`


    * `[:off_broadway_emqtt, :receive_messages, :exception]` - Dispatched after a failure while
      receiving messages from the `ETS` buffer.

      * measurement: `%{duration: native_time}`
      * metadata: `%{client_id: string, demand: non_neg_integer, reason: reason, stacktrace: stacktrace}`


    * `[:off_broadway_emqtt, :receive_messages, :ack]` - Dispatched when acking a message if using
      the default `OffBroadway.EMQTT.MessageHandler` implementation.

      * measurement: `%{time: System.system_time, count: 1}`
      * metadata: `%{topic: string, receipt: receipt}`


    * `[:off_broadway_emqtt, :buffer, :accept_message]` - Dispatched when a message is stored
      into the `ETS` buffer.

      * measurement: `%{time: System.system_time, count: 1}`
      * metadata: `%{client_id: string, topic: string, buffer_size: non_neg_integer}`


    * `[:off_broadway_emqtt, :buffer, :reject_message]` - Dispatched when a message is rejected
      to be stored in the `ETS` buffer because it is full. This occurs when the buffer is full
      and the `buffer_overflow_strategy` is set to `:reject`.

      * measurement: `%{time: System.system_time, count: 1}`
      * metadata: `%{client_id: string, topic: string, buffer_size: non_neg_integer}`


    * `[:off_broadway_emqtt, :buffer, :drop_message]` - Dispatched when a message is dropped from
      the `ETS` buffer to make space for a new. This occurs when the buffer is full and the
      `buffer_overflow_strategy` is set to `:drop_head`.

      * measurement: `%{time: System.system_time, count: 1}`
      * metadata: `%{client_id: string, topic: string, buffer_size: non_neg_integer}`
  """

  use GenStage
  alias Broadway.Producer
  alias OffBroadway.EMQTT.Broker
  alias NimbleOptions.ValidationError

  @behaviour Producer

  @impl true
  def init(opts) do
    with name when is_atom(name) <- get_in(opts, [:config, :name]),
         client_id when is_binary(client_id) <- get_in(opts, [:config, :clientid]),
         emqtt when is_pid(emqtt) <- GenServer.whereis(:"#{OffBroadway.EMQTT.Broker}-#{name}") do
      {:producer,
       %{
         demand: 0,
         drain: false,
         topics: opts[:topics],
         emqtt: emqtt,
         emqtt_name: name,
         receive_timer: nil,
         receive_interval: 100,
         client_id: client_id,
         message_handler: opts[:message_handler],
         broadway: get_in(opts, [:broadway, :name])
       }}
    else
      nil -> {:stop, :error, nil}
    end
  end

  @impl true
  def prepare_for_start(_module, broadway_opts) do
    {producer_module, client_opts} = broadway_opts[:producer][:module]

    case NimbleOptions.validate(client_opts, OffBroadway.EMQTT.Options.definition()) do
      {:ok, opts} ->
        with {:ok, broadway} <- Keyword.fetch(broadway_opts, :name),
             {:ok, config} <- Keyword.fetch(opts, :config),
             {:ok, client_id} <- Keyword.fetch(config, :clientid),
             {host, config} <- Keyword.pop(config, :host),
             config <- Keyword.put(config, :name, emqtt_process_name(client_id)),
             config <- Keyword.put(config, :host, to_charlist(host)) do
          :persistent_term.put(broadway, %{
            config: config,
            # FIXME Acking should be configurable based on if the :emqtt process is started
            # is configured to auto-ack or not.
            on_success: :ack,
            on_failure: :noop
          })

          new_opts = Keyword.put(opts, :config, config)

          with_default_opts =
            put_in(broadway_opts, [:producer, :module], {producer_module, new_opts})

          children = [
            %{id: :broker, start: {OffBroadway.EMQTT.Broker, :start_link, [new_opts]}}
          ]

          {children, with_default_opts}
        end

      {:error, error} ->
        raise ArgumentError, format_error(error)
    end
  end

  @spec emqtt_process_name(String.t()) :: atom()
  def emqtt_process_name(client_id), do: String.to_atom(client_id)

  def message_handler_module({message_handler_module, _}), do: message_handler_module
  def message_handler_module(message_handler_module), do: message_handler_module

  defp format_error(%ValidationError{keys_path: [], message: message}) do
    "invalid configuration given to OffBroadway.EMQTT.Producer.prepare_for_start/2, " <>
      message
  end

  defp format_error(%ValidationError{keys_path: keys_path, message: message}) do
    "invalid configuration given to OffBroadway.EMQTT.Producer.prepare_for_start/2 for key #{inspect(keys_path)}, " <>
      message
  end

  @spec schedule_receive_messages(interval :: non_neg_integer()) :: reference()
  defp schedule_receive_messages(interval),
    do: Process.send_after(self(), :receive_messages, interval)

  defp handle_receive_messages(%{drain: true} = state), do: {:noreply, [], state}

  defp handle_receive_messages(%{demand: demand, receive_timer: nil} = state) when demand > 0 do
    messages = receive_messages_from_handler(state)

    receive_timer =
      case length(messages) do
        0 -> schedule_receive_messages(state.receive_interval)
        _ -> schedule_receive_messages(0)
      end

    {:noreply, messages, %{state | demand: state.demand - length(messages), receive_timer: receive_timer}}
  end

  defp receive_messages_from_handler(state) do
    metadata = %{client_id: state.client_id, demand: state.demand}
    message_handler_module = message_handler_module(state.message_handler)

    :telemetry.span(
      [:off_broadway_emqtt, :receive_messages],
      metadata,
      fn ->
        messages =
          Broker.stream_from_buffer(state.emqtt_name)
          |> Stream.take(state.demand)
          |> Stream.map(&apply(message_handler_module, :handle_message, [&1, state.broadway, []]))
          |> Enum.into([])

        topics =
          Enum.map(messages, &Map.get(&1.metadata, :topic))
          |> Enum.reject(&is_nil/1)

        {messages, Map.put(metadata, :received, length(messages)) |> Map.put(:topics, topics)}
      end
    )
  end

  @impl true
  def handle_demand(demand, %{receive_timer: timer} = state) do
    timer && Process.cancel_timer(timer)
    handle_receive_messages(%{state | demand: state.demand + demand, receive_timer: nil})
  end

  @impl true
  def handle_info(:receive_messages, %{receive_timer: timer} = state) do
    timer && Process.cancel_timer(timer)
    handle_receive_messages(%{state | receive_timer: nil})
  end
end
