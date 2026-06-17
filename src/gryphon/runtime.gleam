import gleam/io
import gleam/list
import gleam/result
import gleam/string

@external(erlang, "gryphon_ffi", "plain_arguments")
pub fn plain_arguments() -> List(String)

@external(erlang, "gryphon_ffi", "unix_millis")
pub fn unix_millis() -> Int

@external(erlang, "gryphon_ffi", "monotonic_millis")
pub fn monotonic_millis() -> Int

@external(erlang, "gryphon_ffi", "ensure_started")
fn ensure_started(application: String) -> Result(Nil, String)

@external(erlang, "gryphon_ffi", "halt")
pub fn halt(code: Int) -> Nil

pub fn ensure_runtime_prereqs() -> Result(Nil, String) {
  use _ <- result.try(ensure_started("crypto"))
  use _ <- result.try(ensure_started("public_key"))
  use _ <- result.try(ensure_started("ssl"))
  use _ <- result.try(ensure_started("inets"))
  Ok(Nil)
}

pub fn fatal(message: String) -> Nil {
  io.println(message)
  halt(1)
}

pub fn join_errors(errors: List(String)) -> String {
  list.reverse(errors)
  |> list.filter(fn(item) { item != "" })
  |> string.join(with: ", ")
}
