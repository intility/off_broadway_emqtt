defmodule OffBroadway.EMQTT.Acknowledger do
  @moduledoc """
  Broadway Acknowledger that sends MQTT ACKs when Broadway messages complete.

  For QoS 1/2, this ties Broadway message processing to MQTT acknowledgements,
  providing protocol-level backpressure via `max_inflight`.
  """

  @behaviour Broadway.Acknowledger

  alias OffBroadway.EMQTT.Connection

  @impl Broadway.Acknowledger
  def ack(ack_ref, successful, failed) do
    ack_options = :persistent_term.get(ack_ref)

    Enum.each(successful, &ack_message(&1, ack_options, :on_success))
    Enum.each(failed, &ack_message(&1, ack_options, :on_failure))
  end

  defp ack_message(message, ack_options, status) do
    %{acknowledger: {_, _, ack_data}} = message
    action = Map.get(ack_options, status, :ack)

    case action do
      :ack -> do_ack(ack_data)
      :noop -> :ok
    end

    emit_telemetry(ack_data, status)
  end

  defp do_ack(%{qos: 0}), do: :ok

  defp do_ack(%{qos: 1, packet_id: packet_id, emqtt_pid: emqtt_pid}) do
    if Process.alive?(emqtt_pid) do
      Connection.puback(emqtt_pid, packet_id)
    end
  end

  defp do_ack(%{qos: 2, packet_id: packet_id, emqtt_pid: emqtt_pid}) do
    if Process.alive?(emqtt_pid) do
      Connection.pubcomp(emqtt_pid, packet_id)
    end
  end

  defp do_ack(_), do: :ok

  defp emit_telemetry(ack_data, status) do
    :telemetry.execute(
      [:off_broadway_emqtt, :receive_message, :ack],
      %{time: System.system_time(), count: 1},
      %{
        topic: ack_data[:topic],
        qos: ack_data[:qos],
        status: status
      }
    )
  end

  @doc """
  Builds acknowledger data for a message.
  """
  @spec build_ack_data(map(), pid()) :: map()
  def build_ack_data(message, emqtt_pid) do
    %{
      emqtt_pid: emqtt_pid,
      packet_id: message[:packet_id],
      qos: message[:qos] || 0,
      topic: message[:topic]
    }
  end
end
