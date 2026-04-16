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
      shared_group: [
        doc: """
        Shared subscription group name. When set, topics are subscribed as
        `$share/{group}/{topic}` which distributes messages across all producer
        instances. Required when using concurrency > 1.
        """,
        type: :string,
        required: false
      ],
      max_inflight: [
        doc: """
        Maximum unACKed QoS 1/2 messages per producer. This is the primary
        backpressure mechanism - the broker will not send more messages until
        existing ones are acknowledged.
        """,
        type: :pos_integer,
        default: 100
      ],
      on_success: [
        doc: "Action when Broadway message succeeds. :ack sends PUBACK to broker.",
        type: {:in, [:ack, :noop]},
        default: :ack
      ],
      on_failure: [
        doc: """
        Action when Broadway message fails.
        - :noop - don't ACK, broker will redeliver after timeout (for QoS 1/2)
        - :ack - ACK anyway, message won't be redelivered
        """,
        type: {:in, [:ack, :noop]},
        default: :noop
      ],
      topics: [
        doc: "List of `{topic, qos}` tuples to subscribe to. Use QoS 1 or 2 for reliable delivery.",
        type: {:custom, __MODULE__, :type_topics, []},
        required: true
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
            doc: "Specify the client identifier. Each producer will append '_N' where N is the producer index.",
            type: :string,
            default: :emqtt.random_client_id()
          ],
          clean_start: [
            doc: """
            Whether the broker should discard any existing session on connect.
            Defaults to false so the broker redelivers unACKed QoS 1/2 messages after a producer
            restart. Set to true only if you explicitly want a fresh session each time and are
            willing to lose in-flight messages on restart.
            """,
            type: :boolean,
            default: false
          ],
          proto_ver: [
            doc: "The MQTT protocol version to use.",
            type: {:in, [:v3, :v4, :v5]},
            default: :v4
          ],
          keepalive: [
            doc: """
            The maximum time interval in seconds that is permitted to elapse between the client
            finishes transmitting one MQTT Control Packet and starts sending the next.
            """,
            type: :pos_integer
          ],
          retry_interval: [
            doc: "Interval in seconds to retry sending packets that have not received a response.",
            type: :pos_integer,
            default: 30
          ],
          will_topic: [
            doc: "Topic of will message, sent by broker on unexpected disconnect.",
            type: :string
          ],
          will_payload: [
            doc: "The payload of the will message.",
            type: :string
          ],
          will_retain: [
            doc: "Whether the will message should be published as retained.",
            type: :boolean,
            default: false
          ],
          will_qos: [
            doc: "The QoS level of the will message.",
            type: {:in, [0, 1, 2]},
            default: 0
          ],
          ack_timeout: [
            doc: "The timeout in seconds for the ack package.",
            type: :pos_integer,
            default: 30
          ],
          force_ping: [
            doc: "If true, ping is sent regardless of other packet activity.",
            type: :boolean,
            default: false
          ],
          custom_auth_callbacks: [
            doc: "A map of custom authentication callback MFAs for MQTT v5.",
            type: {:map, :atom, :mfa}
          ],
          reconnect: [
            doc: """
            Number of reconnect attempts after a disconnection (0 = no reconnect, :infinity = unlimited).
            NOTE: emqtt reconnects the TCP connection but does NOT re-subscribe. You must set
            `clean_start: false` so the broker restores the session and redelivers subscriptions.
            Without `clean_start: false`, messages will silently stop arriving after a reconnect.
            """,
            type: {:or, [{:in, [:infinity]}, :non_neg_integer]},
            required: false
          ],
          reconnect_timeout: [
            doc: "Time in seconds to wait between reconnect attempts. Requires `reconnect` to be set.",
            type: :pos_integer,
            required: false
          ],
          low_mem: [
            doc: "Enable low memory mode. Reduces memory usage at the cost of some performance.",
            type: :boolean,
            required: false
          ],
          properties: [
            doc: """
            MQTT properties to include in the CONNECT packet (MQTT v5 only).
            Keys must be atoms matching MQTT property names, e.g. `%{"Receive-Maximum": 2}`.
            """,
            type: :map,
            required: false
          ]
        ]
      ],
    ]
  end

  def type_topics(value, opts \\ [])

  def type_topics([], _opts), do: {:error, "must not be empty"}

  def type_topics(topics, _opts) when is_list(topics) do
    topics
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, topics}, fn
      {{topic, qos}, _i}, acc when is_binary(topic) ->
        case type_subopt(qos, [{:name, :qos}]) do
          {:ok, _} -> {:cont, acc}
          {:error, reason} -> {:halt, {:error, "invalid qos in topic #{inspect(topic)}: #{reason}"}}
        end

      {item, i}, _acc ->
        {:halt, {:error, "expected {topic, qos} tuple at index #{i}, got: #{inspect(item)}"}}
    end)
  end

  def type_topics(value, _opts),
    do: {:error, "expected a list of {topic, qos} tuples, got: #{inspect(value)}"}

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
