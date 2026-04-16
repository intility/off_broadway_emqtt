defmodule OffBroadway.EMQTT.Test.MessageServer do
  @moduledoc false

  def start_link(client_id \\ "message-server") do
    with {:ok, pid} <-
           :emqtt.start_link(
             host: ~c"localhost",
             port: 1884,
             username: "rw",
             password: "readwrite",
             clientid: client_id
           ),
         {:ok, _} <- :emqtt.connect(pid) do
      {:ok, pid}
    end
  end

  def push_messages(server, topic, messages, qos \\ 0) do
    for message <- messages do
      :emqtt.publish(server, topic, %{}, to_iodata(message), qos: qos)
    end

    :ok
  end

  def to_iodata(term) when is_binary(term), do: term
  def to_iodata(term) when is_list(term), do: term
  def to_iodata(term) when is_integer(term), do: Integer.to_string(term)
  def to_iodata(term) when is_float(term), do: Float.to_string(term)
  def to_iodata(term), do: :erlang.term_to_binary(term)
end
