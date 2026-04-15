defmodule OffBroadway.EMQTT.Connection do
  @moduledoc """
  Manages emqtt connection lifecycle.

  Each producer instance gets its own connection with:
  - `auto_ack: false` for delayed acknowledgements
  - `max_inflight` for protocol-level backpressure
  - Unique client ID per producer index
  """

  require Logger

  @type qos :: 0 | 1 | 2 | :at_most_once | :at_least_once | :exactly_once

  @spec start_link(keyword(), non_neg_integer()) :: {:ok, pid()} | {:error, term()}
  def start_link(config, producer_index) do
    config =
      config
      |> Keyword.put(:auto_ack, false)
      |> Keyword.put(:owner, self())
      |> update_client_id(producer_index)

    with {:ok, pid} <- :emqtt.start_link(config),
         {:ok, _props} <- :emqtt.connect(pid) do
      {:ok, pid}
    end
  end

  @spec subscribe(pid(), String.t() | nil, [{String.t(), qos}]) :: :ok | {:error, term()}
  def subscribe(conn, shared_group, topics) do
    Enum.each(topics, fn {topic, qos} ->
      full_topic = build_topic(topic, shared_group)
      qos_value = normalize_qos(qos)

      case :emqtt.subscribe(conn, {full_topic, qos_value}) do
        {:ok, _props, _reason_codes} -> :ok
        {:error, reason} -> throw({:subscribe_error, topic, reason})
      end
    end)

    :ok
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
    :emqtt.pubrec(conn, packet_id)
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

  defp update_client_id(config, producer_index) do
    base_id = Keyword.get(config, :clientid, :emqtt.random_client_id())
    new_id = "#{base_id}_#{producer_index}"
    Keyword.put(config, :clientid, new_id)
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
