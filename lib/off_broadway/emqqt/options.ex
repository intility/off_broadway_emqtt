defmodule OffBroadway.EMQTT.Options do
  @moduledoc false

  @qos [
    0,
    1,
    2,
    :qos0,
    :qos1,
    :qos2,
    :at_most_once,
    :at_least_once,
    :exactly_once
  ]

  def definition do
    [
      buffer_size: [
        doc: "The maximum number of messages that can be buffered",
        type: :pos_integer,
        default: 10_000
      ],
      buffer_overflow_strategy: [
        doc: "The strategy to use when the buffer is full",
        type: {:in, [:reject, :drop_head]},
        default: :reject
      ],
      topics: [
        doc: "The topics to subscribe to",
        type: {:list, {:tuple, [:string, {:custom, __MODULE__, :type_subopt, [[{:name, :name}]]}]}},
        default: []
      ],
      message_handler: [
        doc: "A module that implements the `OffBroadway.EMQTT.MessageHandler` behaviour",
        type: {:or, [:atom, :mod_arg]},
        default: OffBroadway.EMQTT.MessageHandler
      ],
      config: [
        doc: "Configuration options that will be sent to the `:emqtt` process.",
        type: :non_empty_keyword_list,
        required: true,
        keys: [
          host: [
            doc: "The host of the MQTT broker",
            type: {:custom, __MODULE__, :type_charlist, [[{:name, :name}]]},
            required: true
          ],
          port: [
            doc: "The port to connect to",
            type: :pos_integer,
            default: 1883
          ],
          username: [
            doc: "Username to authenticate with",
            type: :string
          ],
          password: [
            doc: "Password to authenticate with",
            type: :string
          ],
          ssl: [
            doc: "Whether to use SSL",
            type: :boolean
          ],
          ssl_opts: [
            type: :keyword_list,
            required: false,
            keys: [
              cacertfile: [
                doc: "Path to CA certificate file",
                type: :string
              ],
              server_name_indication: [
                doc: "Server name indication",
                type: {:custom, __MODULE__, :type_charlist, [[{:name, :name}]]}
              ],
              verify: [
                doc: "Verify mode",
                type: {:in, [:verify_none, :verify_peer]},
                default: :verify_peer
              ],
              certfile: [
                doc: "Path to client certificate file",
                type: :string
              ],
              keyfile: [
                doc: "Path to client key file",
                type: :string
              ]
            ]
          ],
          ws_path: [
            doc: "The path to the resource.",
            type: :string
          ],
          connect_timeout: [
            doc: "The timeout in seconds for the connection",
            type: :pos_integer,
            default: 60
          ],
          bridge_mode: [
            doc: "Enable bridge mode or not.",
            type: :boolean,
            default: false
          ],
          clientid: [
            doc: "Specify the client identifier.",
            type: :string,
            default: :emqtt.random_client_id()
          ],
          clean_start: [
            doc: "Whether the server should discard any existing sessions and start a new one.",
            type: :boolean,
            default: true
          ],
          proto_ver: [
            doc: "The MQTT protocol version to use.",
            type: {:in, [:v3, :v4, :v5]},
            default: :v4
          ],
          keepalive: [
            doc: """
            The maximum time interval in seconds that is permitted to elapse between the client
            finishes transmitting one MQTT Control Packet and starts sending the next. Will be
            replaced by server `keepalive` from MQTT server.
            """,
            type: :pos_integer
          ],
          max_inflight: [
            doc: """
            The maximum number of QoS 1 and QoS 2 packets in flight. This means the number of packets
            that have been sent, but not yet acked. Will be replaced by server `Receive-Maximum` property
            in a `CONNACK` package. In that case, the lesser of the two values will act as the limit.
            """,
            type: {:or, [:pos_integer, {:in, [:infinity]}]},
            default: :infinity
          ],
          retry_interval: [
            doc: """
            Interval in seconds to retry sending packets that have been sent but not received
            a response.
            """,
            type: :pos_integer,
            default: 30
          ],
          will_topic: [
            doc: """
            Topic of `will` message, a predefined message that the client sets to be sent by the
            server in case of an unexpected disconnects.
            """,
            type: :string
          ],
          will_payload: [
            doc: "The payload of the `will` message.",
            type: :string
          ],
          will_retain: [
            doc: "Whether the `will` message should be published as a retained message.",
            type: :boolean,
            default: false
          ],
          will_qos: [
            doc: "The QoS level of the `will` message.",
            type: {:in, [0, 1, 2]},
            default: 0
          ],
          auto_ack: [
            doc: "The client process will automacally send ack packages like `PUBACK` when receiving a packet.",
            type: :boolean,
            default: true
          ],
          ack_timeout: [
            doc: "The timeout in seconds for the ack package.",
            type: :pos_integer,
            default: 30
          ],
          force_ping: [
            doc: """
            If false and any other packets are sent during the `keepalive` interval, the ping packet will
            not be sent this time. If true, the ping packet will be sent regardless of other packets.
            """,
            type: :boolean,
            default: false
          ],
          custom_auth_callbacks: [
            doc: """
            A map of custom authentication callback MFAs. This configuration enables enhanced authentication
            mechanisms in MQTT v5.
            """,
            type: {:map, :atom, :mfa}
          ]
        ]
      ],
      # For testing purposes
      test_pid: [type: :pid, doc: false],
      message_server: [type: {:or, [:pid, nil]}, doc: false]
    ]
  end

  def type_subopt(value, [{:name, _}]) when value in @qos, do: {:ok, value}
  def type_subopt({:rh, qos} = value, [{:name, _}]) when qos in [0, 1, 2], do: {:ok, value}
  def type_subopt({:qos, qos} = value, [{:name, _}]) when qos in [0, 1, 2], do: {:ok, value}
  def type_subopt({:rap, boolean} = value, [{:name, _}]) when is_boolean(boolean), do: {:ok, value}
  def type_subopt({:nl, boolean} = value, [{:name, _}]) when is_boolean(boolean), do: {:ok, value}

  def type_subopt(value, [{:name, name}]) do
    {:error, "#{inspect(value)} is not a valid subopt value for #{name}"}
  end

  def type_charlist(value, [{:name, _}]) when is_binary(value), do: {:ok, to_charlist(value)}

  def type_charlist(value, [{:name, name}]),
    do: {:error, "#{inspect(value)} is not a valid value for #{name}, expected a binary"}
end
