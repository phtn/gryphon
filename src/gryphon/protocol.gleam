import gleam/bit_array
import gleam/dynamic/decode
import gleam/http.{type Header}
import gleam/json
import gleam/option
import gleam/result
import gleam/string
import gryphon/types

pub fn encode(message: types.ProtocolMessage) -> String {
  case message {
    types.Hello -> json.object([#("type", json.string("hello"))])

    types.HelloOk(tunnel_id, subdomain) ->
      json.object([
        #("type", json.string("hello_ok")),
        #("tunnel_id", json.string(tunnel_id)),
        #("subdomain", json.string(subdomain)),
      ])

    types.Request(request) ->
      json.object([
        #("type", json.string("request")),
        #("request_id", json.string(request.request_id)),
        #("method", json.string(request.method)),
        #("path", json.string(request.path)),
        #("headers", json.array(request.headers, header_json)),
        #("body", json.string(bit_array.base64_encode(request.body, False))),
        #("forwarded_for", json.string(request.forwarded_for)),
        #("forwarded_host", json.string(request.forwarded_host)),
        #("forwarded_proto", json.string(request.forwarded_proto)),
        #("correlation_id", json.string(request.correlation_id)),
      ])

    types.Response(response) ->
      json.object([
        #("type", json.string("response")),
        #("request_id", json.string(response.request_id)),
        #("status", json.int(response.status)),
        #("headers", json.array(response.headers, header_json)),
        #("body", json.string(bit_array.base64_encode(response.body, False))),
      ])

    types.Error(request_id, status, message) ->
      json.object([
        #("type", json.string("error")),
        #("request_id", json.nullable(request_id, json.string)),
        #("status", json.int(status)),
        #("message", json.string(message)),
      ])

    types.Heartbeat -> json.object([#("type", json.string("heartbeat"))])
  }
  |> json.to_string
}

pub fn decode(payload: String) -> Result(types.ProtocolMessage, String) {
  json.parse(payload, message_decoder())
  |> result.map_error(fn(error) { string.inspect(error) })
}

fn message_decoder() -> decode.Decoder(types.ProtocolMessage) {
  use message_type <- decode.field("type", decode.string)
  case message_type {
    "hello" -> decode.success(types.Hello)

    "hello_ok" -> {
      use tunnel_id <- decode.field("tunnel_id", decode.string)
      use subdomain <- decode.field("subdomain", decode.string)
      decode.success(types.HelloOk(tunnel_id:, subdomain:))
    }

    "request" -> request_decoder()
    "response" -> response_decoder()

    "error" -> {
      use request_id <- decode.optional_field(
        "request_id",
        option.None,
        decode.optional(decode.string),
      )
      use status <- decode.field("status", decode.int)
      use message <- decode.field("message", decode.string)
      decode.success(types.Error(request_id:, status:, message:))
    }

    "heartbeat" -> decode.success(types.Heartbeat)
    _ -> decode.failure(types.Heartbeat, expected: "ProtocolMessage")
  }
}

fn request_decoder() -> decode.Decoder(types.ProtocolMessage) {
  use request_id <- decode.field("request_id", decode.string)
  use method <- decode.field("method", decode.string)
  use path <- decode.field("path", decode.string)
  use headers <- decode.field("headers", decode.list(of: header_decoder()))
  use body <- decode.field("body", base64_decoder())
  use forwarded_for <- decode.field("forwarded_for", decode.string)
  use forwarded_host <- decode.field("forwarded_host", decode.string)
  use forwarded_proto <- decode.field("forwarded_proto", decode.string)
  use correlation_id <- decode.field("correlation_id", decode.string)

  decode.success(
    types.Request(types.ForwardRequest(
      request_id:,
      method:,
      path:,
      headers:,
      body:,
      forwarded_for:,
      forwarded_host:,
      forwarded_proto:,
      correlation_id:,
    )),
  )
}

fn response_decoder() -> decode.Decoder(types.ProtocolMessage) {
  use request_id <- decode.field("request_id", decode.string)
  use status <- decode.field("status", decode.int)
  use headers <- decode.field("headers", decode.list(of: header_decoder()))
  use body <- decode.field("body", base64_decoder())

  decode.success(
    types.Response(types.ForwardResponse(request_id:, status:, headers:, body:)),
  )
}

fn header_json(header: Header) -> json.Json {
  json.object([
    #("name", json.string(header.0)),
    #("value", json.string(header.1)),
  ])
}

fn header_decoder() -> decode.Decoder(Header) {
  use name <- decode.field("name", decode.string)
  use value <- decode.field("value", decode.string)
  decode.success(#(name, value))
}

fn base64_decoder() -> decode.Decoder(BitArray) {
  use encoded <- decode.then(decode.string)
  case bit_array.base64_decode(encoded) {
    Ok(value) -> decode.success(value)
    Error(_) -> decode.failure(<<>>, expected: "Base64EncodedBody")
  }
}
