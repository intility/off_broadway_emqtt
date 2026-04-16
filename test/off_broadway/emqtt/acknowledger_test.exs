defmodule OffBroadway.EMQTT.AcknowledgerTest do
  use ExUnit.Case, async: true

  alias OffBroadway.EMQTT.Acknowledger

  # Each test gets a unique ack_ref to avoid persistent_term collisions.
  setup do
    ack_ref = make_ref()
    on_exit(fn -> :persistent_term.erase(ack_ref) end)
    {:ok, ack_ref: ack_ref}
  end

  defp put_ack_opts(ack_ref, opts) do
    :persistent_term.put(ack_ref, Map.new(opts))
  end

  defp broadway_message(ack_ref, ack_data) do
    %Broadway.Message{
      data: "payload",
      metadata: %{},
      acknowledger: {Acknowledger, ack_ref, ack_data}
    }
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    Process.sleep(10)
    pid
  end

  describe "ack/3 - QoS 0" do
    test "does not crash and emits telemetry", %{ack_ref: ack_ref} do
      put_ack_opts(ack_ref, on_success: :ack, on_failure: :noop)
      ack_data = Acknowledger.build_ack_data(%{qos: 0, topic: "t/1"}, self())
      msg = broadway_message(ack_ref, ack_data)

      attach_telemetry(ack_ref)
      assert :ok == Acknowledger.ack(ack_ref, [msg], [])
      assert_receive {:telemetry_ack, %{qos: 0, status: :on_success}}
    end
  end

  describe "ack/3 - on_failure: :noop" do
    test "does not ACK and emits telemetry with on_failure status", %{ack_ref: ack_ref} do
      dead = dead_pid()
      refute Process.alive?(dead)

      put_ack_opts(ack_ref, on_success: :ack, on_failure: :noop)
      ack_data = Acknowledger.build_ack_data(%{qos: 1, packet_id: 1, topic: "t/1"}, dead)
      msg = broadway_message(ack_ref, ack_data)

      attach_telemetry(ack_ref)
      assert :ok == Acknowledger.ack(ack_ref, [], [msg])
      assert_receive {:telemetry_ack, %{qos: 1, status: :on_failure}}
    end
  end

  describe "ack/3 - dead emqtt pid" do
    test "does not crash when emqtt process is gone", %{ack_ref: ack_ref} do
      dead = dead_pid()

      put_ack_opts(ack_ref, on_success: :ack, on_failure: :noop)
      ack_data = Acknowledger.build_ack_data(%{qos: 1, packet_id: 1, topic: "t/1"}, dead)
      msg = broadway_message(ack_ref, ack_data)

      assert :ok == Acknowledger.ack(ack_ref, [msg], [])
    end
  end

  describe "ack/3 - telemetry" do
    test "emits ack event for every message", %{ack_ref: ack_ref} do
      put_ack_opts(ack_ref, on_success: :ack, on_failure: :noop)
      ack_data = Acknowledger.build_ack_data(%{qos: 0, topic: "events/1"}, self())

      msgs = for _ <- 1..3, do: broadway_message(ack_ref, ack_data)

      attach_telemetry(ack_ref)
      Acknowledger.ack(ack_ref, msgs, [])

      for _ <- 1..3 do
        assert_receive {:telemetry_ack, %{topic: "events/1"}}
      end

      refute_receive {:telemetry_ack, _}
    end

    test "emits correct topic and qos in metadata", %{ack_ref: ack_ref} do
      put_ack_opts(ack_ref, on_success: :ack, on_failure: :noop)
      # Use a dead pid so Process.alive? returns false and Connection.pubcomp is not called
      # on a non-emqtt process, which would crash.
      dead = dead_pid()
      ack_data = Acknowledger.build_ack_data(%{qos: 2, topic: "sensor/temp", packet_id: 99}, dead)
      msg = broadway_message(ack_ref, ack_data)

      attach_telemetry(ack_ref)
      Acknowledger.ack(ack_ref, [msg], [])

      assert_receive {:telemetry_ack, %{topic: "sensor/temp", qos: 2, status: :on_success}}
    end

    test "on_success: :noop skips ACK but still emits telemetry", %{ack_ref: ack_ref} do
      put_ack_opts(ack_ref, on_success: :noop, on_failure: :noop)
      # Use a live pid - if :noop incorrectly called do_ack, Connection.puback on self() would crash.
      ack_data = Acknowledger.build_ack_data(%{qos: 1, packet_id: 7, topic: "noop/test"}, self())
      msg = broadway_message(ack_ref, ack_data)

      attach_telemetry(ack_ref)
      assert :ok == Acknowledger.ack(ack_ref, [msg], [])
      assert_receive {:telemetry_ack, %{topic: "noop/test", status: :on_success}}
    end
  end

  # Must be called at most once per test - the handler ID is `ref` and
  # :telemetry.attach/4 raises ArgumentError on duplicate IDs.
  defp attach_telemetry(ref) do
    test_pid = self()

    :telemetry.attach(
      ref,
      [:off_broadway_emqtt, :receive_message, :ack],
      fn _name, _measurements, metadata, _ ->
        send(test_pid, {:telemetry_ack, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
  end
end
