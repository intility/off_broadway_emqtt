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
  def init(_opts) do
    {:producer, %{}}
  end

  @impl true
  def prepare_for_start(_module, broadway_opts) do
    {producer_module, client_opts} = broadway_opts[:producer][:module]

    case NimbleOptions.validate(client_opts, OffBroadway.EMQTT.Options.definition()) do
      {:ok, opts} ->
        with {:ok, config} <- Keyword.fetch(opts, :config),
             {host, config} <- Keyword.pop(config, :host),
             config <- Keyword.put(config, :host, to_charlist(host)) do
          # FIXME - Set these automatically based on producer
          # - name
          # - owner (process to which messages are sent) - use self()?
          # - clientid
          # - cast proto_ver to string if required

          IO.inspect(broadway_opts)
          # Start the `:emqtt` process as part of the supervision tree
          {[%{id: :emqtt, start: {:emqtt, :start_link, [config]}}],
           put_in(broadway_opts, [:producer, :module], {producer_module, opts})}
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

  @impl true
  def handle_demand(_demand, state) do
    {:noreply, [], state}
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}
end
