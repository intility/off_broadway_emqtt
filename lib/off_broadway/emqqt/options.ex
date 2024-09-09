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
          ]
        ]
      ],
      # For testing purposes
      test_pid: [type: :pid, doc: false],
      message_server: [type: :pid, doc: false]
    ]
  end
end
