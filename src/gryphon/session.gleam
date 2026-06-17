import gleam/erlang/process
import gryphon/types

pub type SessionResult {
  Forwarded(types.ForwardResponse)
  Failed(status: Int, message: String)
}

pub type SessionCommand {
  Forward(
    reply_to: process.Subject(SessionResult),
    request: types.ForwardRequest,
  )
  ForceDisconnect
  LivenessCheck
}

pub fn fail(
  reply_to: process.Subject(SessionResult),
  status: Int,
  message: String,
) -> Nil {
  process.send(reply_to, Failed(status:, message:))
}
