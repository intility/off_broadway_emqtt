defmodule OffBroadway.EMQTT.Connection do
  @moduledoc """
  Manages emqtt connection lifecycle.

  Each producer instance gets its own connection with:
  - `auto_ack: false` for delayed acknowledgements
  - `max_inflight` for protocol-level backpressure
  - Unique client ID per producer index
  """

  @type qos :: 0 | 1 | 2 | :at_most_once | :at_least_once | :exactly_once

  @spec start_link(keyword(), non_neg_integer()) :: {:ok, pid()} | {:error, term()}
  def start_link(config, producer_index) do
    config =
      config
      |> Keyword.put(:auto_ack, false)
      |> Keyword.put(:owner, self())
      |> Keyword.put(:clientid, get_client_id(config, producer_index))

    with {:ok, pid} <- :emqtt.start_link(config),
         {:ok, _props} <- :emqtt.connect(pid) do
      {:ok, pid}
    end
  end

  @doc """
  Returns the client ID the connection will advertise to the broker, given a
  producer config and producer index. Pure — callers can use this to correlate
  telemetry or logs without waiting for the connection to be established.
  """
  @spec get_client_id(keyword(), non_neg_integer()) :: String.t()
  def get_client_id(config, producer_index) do
    base_id = Keyword.get(config, :clientid, :emqtt.random_client_id())
    "#{base_id}_#{producer_index}"
  end

  @spec subscribe(pid(), String.t() | nil, [{String.t(), qos}]) ::
          {:ok, [{String.t(), 0..2}]} | {:error, term()}
  def subscribe(conn, shared_group, topics) do
    granted =
      Enum.reduce(topics, [], fn {topic, qos}, acc ->
        full_topic = build_topic(topic, shared_group)
        qos_value = normalize_qos(qos)

        case :emqtt.subscribe(conn, {full_topic, qos_value}) do
          {:ok, _props, reason_codes} ->
            # SUBACK reason codes: 0/1/2 = granted QoS 0/1/2, >= 128 = failure.
            # A successful `{:ok, ...}` response can still contain per-topic
            # failures (e.g. not authorized, topic filter invalid).
            case Enum.filter(reason_codes, &(&1 >= 128)) do
              [] ->
                [granted_qos | _] = reason_codes
                [{topic, granted_qos} | acc]

              failures ->
                throw({:subscribe_error, topic, {:reason_codes, failures}})
            end

          {:error, reason} ->
            throw({:subscribe_error, topic, reason})
        end
      end)

    {:ok, Enum.reverse(granted)}
  catch
    {:subscribe_error, topic, reason} ->
      {:error, {:subscribe_failed, topic, reason}}
  end

  @spec puback(pid(), non_neg_integer()) :: :ok
  def puback(conn, packet_id) do
    :emqtt.puback(conn, packet_id)
  end

  @spec pubcomp(pid(), non_neg_integer()) :: :ok
  def pubcomp(conn, packet_id) do
    :emqtt.pubcomp(conn, packet_id)
  end

  @spec disconnect(pid()) :: :ok
  def disconnect(conn) do
    :emqtt.disconnect(conn)
  catch
    :exit, _ -> :ok
  end

  @spec pause(pid()) :: :ok
  def pause(conn) do
    :emqtt.pause(conn)
  end

  defp build_topic(topic, nil), do: topic
  defp build_topic(topic, shared_group), do: "$share/#{shared_group}/#{topic}"

  defp normalize_qos(:at_most_once), do: 0
  defp normalize_qos(:at_least_once), do: 1
  defp normalize_qos(:exactly_once), do: 2
  defp normalize_qos(:qos0), do: 0
  defp normalize_qos(:qos1), do: 1
  defp normalize_qos(:qos2), do: 2
  defp normalize_qos(qos) when qos in [0, 1, 2], do: qos
end
