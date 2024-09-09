defmodule OffBroadway.EMQTT.Options do
  @moduledoc false

  def definition do
    [
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
            type: :boolean,
            default: false
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
      ]
    ]
  end
end
