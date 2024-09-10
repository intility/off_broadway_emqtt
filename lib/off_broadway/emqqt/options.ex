defmodule OffBroadway.EMQTT.Options do
  @moduledoc false

  def definition do
    [
      buffer_size: [
        doc: "The maximum number of messages that can be buffered",
        type: :pos_integer,
        default: 1000
      ],
      buffer_overflow_strategy: [
        doc: "The strategy to use when the buffer is full",
        type: {:in, [:reject, :drop_head]},
        default: :reject
      ],
      topics: [
        doc: "The topics to subscribe to",
        type: {:list, :string},
        default: []
      ],
      config: [
        doc: "Configuration options that will be sent to the `:emqtt` process.",
        type: :non_empty_keyword_list,
        keys: [
          host: [
            doc: "The host of the MQTT broker",
            type: :string,
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
                type: :string,
                required: true
              ],
              server_name_indication: [
                doc: "Server name indication",
                type: :string
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
            type: :string,
            default: "/mqtt"
          ],
          connect_timeout: [
            doc: "The timeout in milliseconds for the connection",
            type: :pos_integer,
            default: 60_000
          ],
          bridge_mode: [
            doc: "Enable bridge mode or not.",
            type: :boolean,
            default: false
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
            The maximum time interval in milliseconds that is permitted to elapse between the client
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
            Interval in milliseconds to retry sending packets that have been sent but not received
            a response.
            """,
            type: :pos_integer,
            default: 30_000
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
            doc:
              "The client process will automacally send ack packages like `PUBACK` when receiving a packet.",
            type: :boolean,
            default: true
          ],
          ack_timeout: [
            doc: "The timeout in milliseconds for the ack package.",
            type: :pos_integer,
            default: 30_000
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
      message_server: [type: :pid, doc: false]
    ]
  end
end
