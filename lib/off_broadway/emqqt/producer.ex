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
      with emqtt_pid <- Process.whereis(opts[:config][:name]),
           message_handler <- Process.whereis(opts[:message_handler_name]),
           {:ok, _properties} <- :emqtt.connect(emqtt_pid) do
        {:producer,
         %{
           demand: 0,
           drain: false,
           topics: opts[:topics],
           emqtt_pid: emqtt_pid,
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
        with {:ok, config} <- Keyword.fetch(opts, :config),
             {:ok, message_handler} <- Keyword.fetch(opts, :message_handler),
             {host, config} <- Keyword.pop(config, :host),
             config <- Keyword.put(config, :name, emqtt_process_name(config)),
             config <- Keyword.put(config, :host, to_charlist(host)) do
          :persistent_term.put(broadway_opts[:name], %{
            config: config,
            # FIXME
            on_success: :ack,
            on_failure: :ack
          })

          with_default_opts =
            put_in(
              broadway_opts,
              [:producer, :module],
              {producer_module,
               Keyword.put(opts, :config, config)
               |> Keyword.put(:message_handler_name, message_handler_process_name(config))}
            )

          children = [
            %{
              id: :message_handler,
              start: {elem(message_handler, 0), :start_link, [elem(message_handler, 1) ++ with_default_opts]}
              # start: {message_handler, :start_link, [args ++ with_default_opts]}
            },
            %{
              id: :emqtt,
              start: {:emqtt, :start_link, [config ++ [msg_handler: emqtt_message_handler(with_default_opts)]]}
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

  @spec emqtt_process_name(Keyword.t()) :: atom()
  defp message_handler_process_name(config), do: String.to_atom(config[:clientid] <> "_message_handler")

  @spec emqtt_process_name(Keyword.t()) :: atom()
  defp emqtt_process_name(config), do: String.to_atom(config[:clientid])

  @spec emqtt_subscribe(pid(), {String.t(), term()}) ::
          {:ok, port(), [pos_integer()]} | {:error, term()}
  defp emqtt_subscribe(emqtt_pid, topics) when is_list(topics),
    do: Enum.map(topics, &emqtt_subscribe(emqtt_pid, &1))

  defp emqtt_subscribe(emqtt_pid, topic) when is_tuple(topic),
    do: :emqtt.subscribe(emqtt_pid, topic)

  # TODO User should be able to define their own message handler
  @spec emqtt_message_handler(Keyword.t()) :: map()
  defp emqtt_message_handler(opts) do
    %{
      connected: {OffBroadway.EMQTT.MessageHandler, :handle_connect, []},
      disconnected: {OffBroadway.EMQTT.MessageHandler, :handle_disconnect, []},
      publish: {OffBroadway.EMQTT.MessageHandler, :handle_message, [[ack_ref: opts[:name]]]},
      pubrel: {OffBroadway.EMQTT.MessageHandler, :handle_pubrel, []}
    }
  end

  @impl true
  def handle_demand(_demand, %{emqtt_subscribed: false} = state) do
    emqtt_subscribe(state.emqtt_pid, state.topics)
    {:noreply, [], %{state | emqtt_subscribed: true}}
  end

  def handle_demand(demand, state) do
    IO.inspect(demand, label: "Handle demand from #{inspect(Process.info(self(), :registered_name))}")

    # GenServer.call(state.message_handler, {:demand, demand})
    # |> IO.inspect()

    {:noreply, [], state}
  end

  @impl true
  def handle_info(message, state) do
    IO.inspect(message, label: "Handle info")
    {:noreply, state}
  end
end
