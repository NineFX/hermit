//// Name conversions between Gleam, Erlang, and Rust.

import gleam/list
import gleam/string

/// The atom Gleam uses on the BEAM for a constructor: `HTTPError` becomes
/// `h_t_t_p_error`, matching the Gleam compiler.
pub fn constructor_tag(constructor: String) -> String {
  constructor
  |> string.to_graphemes
  |> list.index_map(fn(grapheme, index) {
    let lower = string.lowercase(grapheme)
    case index > 0 && lower != grapheme {
      True -> "_" <> lower
      False -> lower
    }
  })
  |> string.concat
}

/// Writes an Erlang atom, quoting it when it is not a bare atom.
pub fn erlang_atom(name: String) -> String {
  case is_bare_atom(name) && !list.contains(erlang_reserved_words, name) {
    True -> name
    False ->
      "'"
      <> name
      |> string.replace("\\", "\\\\")
      |> string.replace("'", "\\'")
      <> "'"
  }
}

fn is_bare_atom(name: String) -> Bool {
  case string.to_graphemes(name) {
    [first, ..rest] ->
      is_lowercase_letter(first)
      && list.all(rest, fn(grapheme) {
        is_lowercase_letter(grapheme)
        || is_uppercase_letter(grapheme)
        || is_digit(grapheme)
        || grapheme == "_"
        || grapheme == "@"
      })
    [] -> False
  }
}

/// Turns a name from the interface into a Rust identifier that is not a
/// keyword, by appending an underscore to keywords.
pub fn rust_identifier(name: String) -> String {
  case list.contains(rust_keywords, name) {
    True -> name <> "_"
    False -> name
  }
}

/// Turns an Erlang module name into a Rust crate name: anything that is not
/// an ASCII letter, digit, or underscore becomes an underscore.
pub fn crate_name(erlang_module: String) -> String {
  erlang_module
  |> string.to_graphemes
  |> list.map(fn(grapheme) {
    case
      is_lowercase_letter(grapheme)
      || is_uppercase_letter(grapheme)
      || is_digit(grapheme)
    {
      True -> grapheme
      False -> "_"
    }
  })
  |> string.concat
}

fn is_lowercase_letter(grapheme: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyz", grapheme)
  && string.length(grapheme) == 1
}

fn is_uppercase_letter(grapheme: String) -> Bool {
  string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", grapheme)
  && string.length(grapheme) == 1
}

fn is_digit(grapheme: String) -> Bool {
  string.contains("0123456789", grapheme) && string.length(grapheme) == 1
}

const erlang_reserved_words = [
  "after", "and", "andalso", "band", "begin", "bnot", "bor", "bsl", "bsr",
  "bxor", "case", "catch", "cond", "div", "else", "end", "fun", "if", "let",
  "maybe", "not", "of", "or", "orelse", "receive", "rem", "try", "when", "xor",
]

const rust_keywords = [
  "abstract", "as", "async", "await", "become", "box", "break", "const",
  "continue", "crate", "do", "dyn", "else", "enum", "extern", "false", "final",
  "fn", "for", "gen", "if", "impl", "in", "let", "loop", "macro", "match", "mod",
  "move", "mut", "override", "priv", "pub", "ref", "return", "self", "Self",
  "static", "struct", "super", "trait", "true", "try", "type", "typeof",
  "unsafe", "unsized", "use", "virtual", "where", "while", "yield",
]
