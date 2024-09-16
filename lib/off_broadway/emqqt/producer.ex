defmodule OffBroadway.EMQTT.Producer do
  @moduledoc """
  A MQTT producer based on [emqtt](https://github.com/emqx/emqtt) for Broadway.

  ## Producer options

  #{NimbleOptions.docs(OffBroadway.EMQTT.Options.definition())}

  ## Acknowledgements

  TBD

  ## Telemetry

  This library exposes the following telemetry events:

  TBD
  """

  use GenStage
  alias Broadway.Producer
  alias NimbleOptions.ValidationError

  @behaviour Producer

  @impl true
  def init(opts) do
    try do
      with client_id <- get_in(opts, [:config, :name]),
           emqtt <- Process.whereis(client_id),
           message_handler <- Process.whereis(opts[:message_handler_name]),
           {message_handler_mod, _} <- opts[:message_handler],
           {:ok, _properties} <- :emqtt.connect(emqtt) do
        {:producer,
         %{
           demand: 0,
           drain: false,
           topics: opts[:topics],
           emqtt: emqtt,
           emqtt_client_id: client_id,
           emqtt_subscribed: false,
           message_handler: message_handler,
           message_handler_mod: message_handler_mod,
           receive_timer: nil,
           receive_interval: 100,
           broadway: opts[:broadway][:name]
         }}
      else
        {:error, {reason, _}} -> {:stop, reason, nil}
      end
    rescue
      ArgumentError -> {:stop, :emqtt_client_not_found, nil}
    end
  end

  @impl true
  def prepare_for_start(_module, broadway_opts) do
    {producer_module, client_opts} = broadway_opts[:producer][:module]

    case NimbleOptions.validate(client_opts, OffBroadway.EMQTT.Options.definition()) do
      {:ok, opts} ->
        with {:ok, broadway} <- Keyword.fetch(broadway_opts, :name),
             {:ok, config} <- Keyword.fetch(opts, :config),
             {:ok, handler} <- Keyword.fetch(opts, :message_handler),
             {:ok, client_id} <- Keyword.fetch(config, :clientid),
             {host, config} <- Keyword.pop(config, :host),
             config <- Keyword.put(config, :name, emqtt_process_name(client_id)),
             config <- Keyword.put(config, :host, to_charlist(host)) do
          :persistent_term.put(broadway, %{
            config: config,
            # FIXME
            on_success: :ack,
            on_failure: :noop
          })

          new_opts =
            Keyword.put(opts, :config, config)
            |> Keyword.put(:counter, :counters.new(2, [:atomics]))
            |> Keyword.put(:message_handler_name, message_handler_process_name(client_id))

          with_default_opts =
            put_in(broadway_opts, [:producer, :module], {producer_module, new_opts})

          children = [
            %{
              id: :message_handler,
              start: {elem(handler, 0), :start_link, [elem(handler, 1) ++ with_default_opts]}
            },
            %{
              id: :emqtt_server,
              start: {:emqtt, :start_link, [config ++ [msg_handler: emqtt_message_handler(broadway, new_opts)]]}
            }
          ]

          {children, with_default_opts}
        end

      {:error, error} ->
        raise ArgumentError, format_error(error)
    end
  end

  @spec message_handler_process_name(String.t()) :: atom()
  def message_handler_process_name(client_id), do: String.to_atom(client_id <> "_message_handler")

  @spec emqtt_process_name(String.t()) :: atom()
  def emqtt_process_name(client_id), do: String.to_atom(client_id)

  defp format_error(%ValidationError{keys_path: [], message: message}) do
    "invalid configuration given to OffBroadway.EMQTT.Producer.prepare_for_start/2, " <>
      message
  end

  defp format_error(%ValidationError{keys_path: keys_path, message: message}) do
    "invalid configuration given to OffBroadway.EMQTT.Producer.prepare_for_start/2 for key #{inspect(keys_path)}, " <>
      message
  end

  @spec emqtt_subscribe(pid(), {String.t(), term()}) ::
          {:ok, port(), [pos_integer()]} | {:error, term()}
  defp emqtt_subscribe(emqtt, topics) when is_list(topics),
    do: Enum.map(topics, &emqtt_subscribe(emqtt, &1))

  defp emqtt_subscribe(emqtt, topic) when is_tuple(topic),
    do: {:ok, _, _} = :emqtt.subscribe(emqtt, topic)

  @spec schedule_receive_messages(interval :: non_neg_integer()) :: reference()
  defp schedule_receive_messages(interval),
    do: Process.send_after(self(), :receive_messages, interval)

  @spec emqtt_message_handler(atom() | tuple(), Keyword.t()) :: map()
  defp emqtt_message_handler(broadway, opts) do
    {message_handler, args} = opts[:message_handler]

    %{
      connected: {message_handler, :handle_connect, args},
      disconnected: {message_handler, :handle_disconnect, args},
      publish: {message_handler, :handle_message, args ++ [broadway, opts]},
      pubrel: {message_handler, :handle_pubrel, args}
    }
  end

  defp handle_receive_messages(%{drain: true} = state), do: {:noreply, [], state}

  defp handle_receive_messages(%{demand: demand, receive_timer: nil} = state) when demand > 0 do
    messages = receive_messages_from_handler(state)

    receive_timer =
      case length(messages) do
        0 ->
          IO.inspect("empty messages, scheduling receive_messages")
          schedule_receive_messages(state.receive_interval)

        _ ->
          IO.inspect("non-empty messages, scheduling receive_messages")
          schedule_receive_messages(0)
      end

    {:noreply, messages, %{state | demand: state.demand - length(messages), receive_timer: receive_timer}}
  end

  defp receive_messages_from_handler(state) do
    metadata = %{demand: state.demand}

    :telemetry.span(
      [:off_broadway_emqtt, :receive_messages],
      metadata,
      fn ->
        with opts <- Keyword.new(broadway: state.broadway, client_id: state.emqtt_client_id),
             messages <- apply(state.message_handler_mod, :receive_messages, [state.demand, opts]),
             count <- length(messages) do
          {messages, Map.put(metadata, :received, count)}
        end
      end
    )
  end

  @impl true
  def handle_demand(demand, %{receive_timer: timer} = state) do
    timer && Process.cancel_timer(timer)

    unless state.emqtt_subscribed,
      do: emqtt_subscribe(state.emqtt, state.topics)

    handle_receive_messages(%{state | demand: state.demand + demand, receive_timer: nil})
  end

  @impl true
  def handle_info(:receive_messages, %{receive_timer: timer} = state) do
    timer && Process.cancel_timer(timer)
    IO.inspect("Received messages timer fired")
    handle_receive_messages(%{state | receive_timer: nil})
  end
end
