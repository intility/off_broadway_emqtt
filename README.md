# OffBroadway.EMQTT

## Building

By default, `:emqtt` compiles the `Quic` library. It is possible to build without by setting the environment variable
`BUILD_WITHOUT_QUIC=1`.

``` shell
BUILD_WITHOUT_QUIC=1 mix compile
```


**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `off_broadway_emqtt` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:off_broadway_emqtt, "~> 0.1.0", system_env: [{"BUILD_WITHOUT_QUIC", "1"}]}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/off_broadway_emqtt>.

