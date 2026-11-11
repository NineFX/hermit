//// Reads hermit's settings from a project's `gleam.toml`.
////
//// ```toml
//// [[tools.hermit.nif]]
//// module = "my_app/native"
//// dirty_cpu = ["fib"]
//// dirty_io = ["read_all"]
//// ```

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import tom

pub type Config {
  Config(
    /// The project's name, which is also its OTP application.
    project: String,
    nifs: List(Nif),
  )
}

/// A Gleam module whose Erlang externals are NIFs.
pub type Nif {
  Nif(module: String, dirty_cpu: List(String), dirty_io: List(String))
}

pub const example =
  "[[tools.hermit.nif]]
module = \"my_app/native\""

pub fn parse(source: String) -> Result(Config, String) {
  use toml <- result.try(
    tom.parse(source)
    |> result.replace_error("gleam.toml is not valid TOML"),
  )
  use project <- result.try(
    tom.get_string(toml, ["name"])
    |> result.replace_error("gleam.toml has no `name`"),
  )
  use tables <- result.try(
    case tom.get_array(toml, ["tools", "hermit", "nif"]) {
      Ok([]) | Error(tom.NotFound(_)) ->
        Error(
          "gleam.toml declares no NIF modules. Add one for each Gleam module "
          <> "whose Erlang externals are NIFs:\n\n"
          <> example,
        )
      Ok(tables) -> Ok(tables)
      Error(_) ->
        Error("`tools.hermit.nif` in gleam.toml must be an array of tables")
    },
  )
  use nifs <- result.map(list.try_map(tables, parse_nif))
  Config(project:, nifs:)
}

fn parse_nif(table: tom.Toml) -> Result(Nif, String) {
  use table <- result.try(case table {
    tom.Table(table) | tom.InlineTable(table) -> Ok(table)
    _ -> Error("each `tools.hermit.nif` entry must be a table")
  })
  use module <- result.try(
    tom.get_string(table, ["module"])
    |> result.replace_error("each `tools.hermit.nif` entry needs a `module`"),
  )
  use dirty_cpu <- result.try(strings(table, module, "dirty_cpu"))
  use dirty_io <- result.map(strings(table, module, "dirty_io"))
  Nif(module:, dirty_cpu:, dirty_io:)
}

fn strings(
  table: Dict(String, tom.Toml),
  module: String,
  key: String,
) -> Result(List(String), String) {
  let wrong_type =
    "`" <> key <> "` for " <> module <> " must be an array of function names"
  case tom.get_array(table, [key]) {
    Error(tom.NotFound(_)) -> Ok([])
    Error(_) -> Error(wrong_type)
    Ok(values) ->
      list.try_map(values, tom.as_string) |> result.replace_error(wrong_type)
  }
}
