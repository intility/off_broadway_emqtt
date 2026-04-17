defmodule OffBroadway.EMQTT.ConnectTest do
  use ExUnit.Case

  @hostname ~c"localhost"
  @host [host: @hostname]
  @credentials [username: "rw", password: "readwrite"]
  @cert_dir Path.join(File.cwd!(), ".mosquitto/certs")
  @ssl_opts [
    cacertfile: Path.join(@cert_dir, "ca.crt"),
    server_name_indication: @hostname,
    verify: :verify_peer
  ]
  @client_cert [
    certfile: Path.join(@cert_dir, "client.crt"),
    keyfile: Path.join(@cert_dir, "client.key")
  ]

  @opts_1883 @host ++ [port: 1883]
  @opts_1884 @host ++ @credentials ++ [port: 1884]
  @opts_8883 @host ++ [ssl: true, ssl_opts: @ssl_opts, port: 8883]
  @opts_8884 @host ++ [ssl: true, ssl_opts: @ssl_opts ++ @client_cert, port: 8884]
  @opts_8885 @host ++ @credentials ++ [ssl: true, ssl_opts: @ssl_opts, port: 8885]

  describe "connecting to local Mosquitto" do
    test "at port 1883 without authentication" do
      {:ok, pid} = :emqtt.start_link(@opts_1883)

      assert {:ok, _} = :emqtt.connect(pid)
      stop_emqtt(pid)
    end

    test "at port 1884 using username/password authentication" do
      {:ok, pid} = :emqtt.start_link(@opts_1884)

      assert {:ok, _} = :emqtt.connect(pid)
      stop_emqtt(pid)
    end

    test "at port 8883 using TLS without authentication" do
      {:ok, pid} = :emqtt.start_link(@opts_8883)

      assert {:ok, _} = :emqtt.connect(pid)
      stop_emqtt(pid)
    end

    test "at port 8884 using TLS with client certificate authentication" do
      {:ok, pid} = :emqtt.start_link(@opts_8884)

      assert {:ok, _} = :emqtt.connect(pid)
      stop_emqtt(pid)
    end

    test "at port 8885 using TLS with username/password authentication" do
      {:ok, pid} = :emqtt.start_link(@opts_8885)

      assert {:ok, _} = :emqtt.connect(pid)
      stop_emqtt(pid)
    end
  end

  defp stop_emqtt(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :normal)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end
end
