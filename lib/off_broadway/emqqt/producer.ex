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
      with emqtt <- Process.whereis(opts[:config][:name]),
           message_handler <- Process.whereis(opts[:message_handler_name]),
           {:ok, _properties} <- :emqtt.connect(emqtt) do
        {:producer,
         %{
           demand: 0,
           drain: false,
           topics: opts[:topics],
           emqtt: emqtt,
           emqtt_client_id: opts[:config][:name],
           emqtt_subscribed: false,
           message_handler: message_handler,
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

          new_opts = Keyword.put(opts, :config, config)

          with_default_opts =
            put_in(
              broadway_opts,
              [:producer, :module],
              {producer_module, Keyword.put(new_opts, :message_handler_name, message_handler_process_name(client_id))}
            )

          children = [
            %{
              id: :message_handler,
              start: {elem(handler, 0), :start_link, [elem(handler, 1) ++ with_default_opts]}
            },
            %{
              id: :emqtt,
              start: {:emqtt, :start_link, [config ++ [msg_handler: emqtt_message_handler(broadway, new_opts)]]}
            }
          ]

          {children, with_default_opts}
        end

      {:error, error} ->
        raise ArgumentError, format_error(error)
    end
  end

  defp format_error(%ValidationError{keys_path: [], message: message}) do
    "invalid configuration given to OffBroadway.EMQTT.Producer.prepare_for_start/2, " <>
      message
  end

  defp format_error(%ValidationError{keys_path: keys_path, message: message}) do
    "invalid configuration given to OffBroadway.EMQTT.Producer.prepare_for_start/2 for key #{inspect(keys_path)}, " <>
      message
  end

  @spec emqtt_process_name(String.t()) :: atom()
  def message_handler_process_name(client_id), do: String.to_atom(client_id <> "_message_handler")

  @spec emqtt_process_name(String.t()) :: atom()
  def emqtt_process_name(client_id), do: String.to_atom(client_id)

  @spec emqtt_subscribe(pid(), {String.t(), term()}) ::
          {:ok, port(), [pos_integer()]} | {:error, term()}
  defp emqtt_subscribe(emqtt, topics) when is_list(topics),
    do: Enum.map(topics, &emqtt_subscribe(emqtt, &1))

  defp emqtt_subscribe(emqtt, topic) when is_tuple(topic),
    do: :emqtt.subscribe(emqtt, topic)

  # TODO User should be able to define their own message handler
  @spec emqtt_message_handler(atom() | tuple(), Keyword.t()) :: map()
  defp emqtt_message_handler(broadway, opts) do
    %{
      connected: {OffBroadway.EMQTT.MessageHandler, :handle_connect, []},
      disconnected: {OffBroadway.EMQTT.MessageHandler, :handle_disconnect, []},
      publish: {OffBroadway.EMQTT.MessageHandler, :handle_message, [broadway, opts]},
      pubrel: {OffBroadway.EMQTT.MessageHandler, :handle_pubrel, []}
    }
  end

  @impl true
  def handle_demand(_demand, %{emqtt_subscribed: false} = state) do
    emqtt_subscribe(state.emqtt, state.topics)
    {:noreply, [], %{state | emqtt_subscribed: true}}
  end

  def handle_demand(demand, state) do
    # TODO Use receive_messages callback
    messages = GenServer.call(state.message_handler, {:dequeue, demand})
    {:noreply, messages, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end
