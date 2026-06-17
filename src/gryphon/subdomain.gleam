import gleam/list
import gleam/result
import gleam/string
import gryphon/token

pub fn validate(value: String) -> Result(String, String) {
  let value = string.lowercase(string.trim(value))

  case value == "" {
    True -> Error("subdomain cannot be empty")
    False ->
      case string.length(value) < 3 || string.length(value) > 63 {
        True -> Error("subdomain must be between 3 and 63 characters")
        False ->
          case string.starts_with(value, "-") || string.ends_with(value, "-") {
            True -> Error("subdomain cannot start or end with '-'")
            False ->
              case list.all(string.to_graphemes(value), valid_character) {
                True -> Ok(value)
                False ->
                  Error(
                    "subdomain may only contain lowercase letters, digits, and '-'",
                  )
              }
          }
      }
  }
}

pub fn from_host(host: String, base_domain: String) -> Result(String, Nil) {
  let host = host |> normalize_host()
  let base_domain = base_domain |> string.lowercase() |> normalize_host()
  let suffix = "." <> base_domain

  case host == base_domain || !string.ends_with(host, suffix) {
    True -> Error(Nil)
    False -> {
      let subdomain =
        string.slice(
          from: host,
          at_index: 0,
          length: string.length(host) - string.length(suffix),
        )
      validate(subdomain)
      |> result.replace_error(Nil)
    }
  }
}

pub fn random() -> String {
  token.random_subdomain_candidate()
}

pub fn normalize_host(host: String) -> String {
  let lowered = host |> string.trim() |> string.lowercase()
  case string.starts_with(lowered, "[") {
    True -> lowered
    False ->
      case string.split_once(lowered, ":") {
        Ok(#(hostname, _port)) -> hostname
        Error(_) -> lowered
      }
  }
}

fn valid_character(character: String) -> Bool {
  case character {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9"
    | "-" -> True
    _ -> False
  }
}
