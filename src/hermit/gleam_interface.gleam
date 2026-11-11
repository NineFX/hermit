//// Reads a NIF library out of a Gleam module.
////
//// Every function in the module annotated with `@external(erlang, ...)` is
//// a NIF, and all of them must name the same Erlang module. Custom types the
//// signatures use become Rust types; custom types without constructors
//// become Rust resources.

import glance
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import glexer/token
import hermit/ir
import hermit/naming

pub type Options {
  Options(
    /// The OTP application that owns the compiled library.
    otp_app: String,
    /// The path of the module, used in messages and generated headers.
    path: String,
    /// Functions to run on dirty CPU schedulers, by Gleam name.
    dirty_cpu: List(String),
    /// Functions to run on dirty I/O schedulers, by Gleam name.
    dirty_io: List(String),
  )
}

/// A problem with the interface, optionally tied to a place in the source.
pub type Diagnostic {
  Diagnostic(span: Option(glance.Span), message: String)
}

/// Formats a diagnostic as `path:line:column: message`.
pub fn describe(
  diagnostic: Diagnostic,
  path: String,
  source: String,
) -> String {
  case diagnostic.span {
    Some(span) -> {
      let #(line, column) = line_and_column(source, span.start)
      path
      <> ":"
      <> int.to_string(line)
      <> ":"
      <> int.to_string(column)
      <> ": "
      <> diagnostic.message
    }
    None -> path <> ": " <> diagnostic.message
  }
}

fn line_and_column(source: String, byte_offset: Int) -> #(Int, Int) {
  let before =
    bit_array.from_string(source)
    |> bit_array.slice(0, byte_offset)
    |> result.try(bit_array.to_string)
    |> result.unwrap("")
  let lines = string.split(before, "\n")
  let column = case list.last(lines) {
    Ok(last) -> string.length(last) + 1
    Error(Nil) -> 1
  }
  #(list.length(lines), column)
}

pub fn read(
  source: String,
  options: Options,
) -> Result(ir.Library, List(Diagnostic)) {
  use module <- result.try(
    glance.module(source) |> result.map_error(fn(e) { [parse_diagnostic(e)] }),
  )
  let scope = new_scope(module)
  use externals <- result.try(find_externals(module, options.path))
  use erlang_module <- result.try(single_erlang_module(externals))
  use functions <- result.try(
    externals
    |> list.map(fn(external) { read_function(scope, external, options) })
    |> collect,
  )
  use types <- result.try(read_types(scope, functions))
  use _ <- result.try(check_schedules(functions, options))
  use _ <- result.try(check_unique_nif_names(externals, functions))
  Ok(ir.Library(
    erlang_module:,
    otp_app: options.otp_app,
    source: options.path,
    types:,
    functions:,
  ))
}

fn parse_diagnostic(error: glance.Error) -> Diagnostic {
  case error {
    glance.UnexpectedEndOfInput ->
      Diagnostic(None, "the module ends before its last definition does")
    glance.UnexpectedToken(token:, position:) ->
      Diagnostic(
        Some(glance.Span(position.byte_offset, position.byte_offset)),
        "unexpected `" <> token.to_source(token) <> "`",
      )
  }
}

// Externals -------------------------------------------------------------------

type External {
  External(
    function: glance.Function,
    erlang_module: String,
    erlang_name: String,
  )
}

fn find_externals(
  module: glance.Module,
  path: String,
) -> Result(List(External), List(Diagnostic)) {
  let externals =
    list.filter_map(module.functions, fn(definition) {
      list.find_map(definition.attributes, fn(attribute) {
        case attribute {
          glance.Attribute(
            name: "external",
            arguments: [
              glance.Variable(name: "erlang", ..),
              glance.String(value: erlang_module, ..),
              glance.String(value: erlang_name, ..),
            ],
          ) -> Ok(External(definition.definition, erlang_module, erlang_name))
          _ -> Error(Nil)
        }
      })
    })
    |> list.sort(fn(a, b) {
      int.compare(a.function.location.start, b.function.location.start)
    })
  case externals {
    [] ->
      Error([
        Diagnostic(
          None,
          "found no `@external(erlang, ...)` functions in "
            <> path
            <> ", so there are no NIFs to generate",
        ),
      ])
    _ -> Ok(externals)
  }
}

fn single_erlang_module(
  externals: List(External),
) -> Result(String, List(Diagnostic)) {
  let assert [first, ..rest] = externals
  case list.filter(rest, fn(e) { e.erlang_module != first.erlang_module }) {
    [] -> Ok(first.erlang_module)
    others ->
      Error(
        list.map(others, fn(other) {
          Diagnostic(
            Some(other.function.location),
            "`"
              <> other.function.name
              <> "` is external to Erlang module `"
              <> other.erlang_module
              <> "`, but `"
              <> first.function.name
              <> "` is external to `"
              <> first.erlang_module
              <> "`. All NIFs in a module must share one Erlang module.",
          )
        }),
      )
  }
}

fn read_function(
  scope: Scope,
  external: External,
  options: Options,
) -> Result(ir.Function, List(Diagnostic)) {
  let function = external.function
  let parameters =
    function.parameters
    |> list.index_map(fn(parameter, index) {
      read_parameter(scope, function, parameter, index)
    })
    |> collect
  let return = case function.return {
    Some(type_) -> resolve(scope, type_, [])
    None ->
      Error([
        Diagnostic(
          Some(function.location),
          "`" <> function.name <> "` needs a return type annotation",
        ),
      ])
  }
  case parameters, return {
    Ok(parameters), Ok(return) ->
      Ok(ir.Function(
        name: function.name,
        erlang_name: external.erlang_name,
        parameters:,
        return:,
        schedule: schedule(function.name, options),
      ))
    Error(a), Error(b) -> Error(list.append(a, b))
    Error(errors), _ | _, Error(errors) -> Error(errors)
  }
}

fn read_parameter(
  scope: Scope,
  function: glance.Function,
  parameter: glance.FunctionParameter,
  index: Int,
) -> Result(ir.Parameter, List(Diagnostic)) {
  let name = case parameter.name {
    glance.Named(name) -> name
    glance.Discarded("") -> "arg" <> int.to_string(index)
    glance.Discarded(name) -> "_" <> name
  }
  case parameter.type_ {
    Some(type_) ->
      resolve(scope, type_, [])
      |> result.map(fn(type_) { ir.Parameter(name:, type_:) })
    None ->
      Error([
        Diagnostic(
          Some(function.location),
          "parameter `"
            <> name
            <> "` of `"
            <> function.name
            <> "` needs a type annotation",
        ),
      ])
  }
}

fn schedule(name: String, options: Options) -> ir.Schedule {
  case
    list.contains(options.dirty_cpu, name),
    list.contains(options.dirty_io, name)
  {
    True, _ -> ir.DirtyCpu
    _, True -> ir.DirtyIo
    False, False -> ir.Normal
  }
}

fn check_schedules(
  functions: List(ir.Function),
  options: Options,
) -> Result(Nil, List(Diagnostic)) {
  let names = list.map(functions, fn(function) { function.name })
  let unknown = fn(setting, configured) {
    configured
    |> list.filter(fn(name) { !list.contains(names, name) })
    |> list.map(fn(name) {
      Diagnostic(
        None,
        "`"
          <> setting
          <> "` lists `"
          <> name
          <> "`, which is not an external function in this module",
      )
    })
  }
  let both =
    options.dirty_cpu
    |> list.filter(list.contains(options.dirty_io, _))
    |> list.map(fn(name) {
      Diagnostic(
        None,
        "`" <> name <> "` is listed in both `dirty_cpu` and `dirty_io`",
      )
    })
  case
    list.flatten([
      unknown("dirty_cpu", options.dirty_cpu),
      unknown("dirty_io", options.dirty_io),
      both,
    ])
  {
    [] -> Ok(Nil)
    diagnostics -> Error(diagnostics)
  }
}

fn check_unique_nif_names(
  externals: List(External),
  functions: List(ir.Function),
) -> Result(Nil, List(Diagnostic)) {
  let diagnostics =
    list.zip(externals, functions)
    |> list.fold(#(dict.new(), []), fn(acc, pair) {
      let #(seen, diagnostics) = acc
      let #(external, function) = pair
      let key = #(function.erlang_name, list.length(function.parameters))
      case dict.get(seen, key) {
        Ok(previous) -> #(seen, [
          Diagnostic(
            Some(external.function.location),
            "`"
              <> function.name
              <> "` and `"
              <> previous
              <> "` are both external to `"
              <> function.erlang_name
              <> "/"
              <> int.to_string(key.1)
              <> "`",
          ),
          ..diagnostics
        ])
        Error(Nil) -> #(dict.insert(seen, key, function.name), diagnostics)
      }
    })
    |> fn(acc) { list.reverse(acc.1) }
  case diagnostics {
    [] -> Ok(Nil)
    _ -> Error(diagnostics)
  }
}

// Types -----------------------------------------------------------------------

type Scope {
  Scope(
    custom_types: Dict(String, glance.CustomType),
    aliases: Dict(String, glance.TypeAlias),
    imports: List(glance.Import),
  )
}

fn new_scope(module: glance.Module) -> Scope {
  Scope(
    custom_types: module.custom_types
      |> list.map(fn(d) { #(d.definition.name, d.definition) })
      |> dict.from_list,
    aliases: module.type_aliases
      |> list.map(fn(d) { #(d.definition.name, d.definition) })
      |> dict.from_list,
    imports: list.map(module.imports, fn(d) { d.definition }),
  )
}

/// Converts a Gleam type annotation into an IR type. `expanding` holds the
/// aliases being expanded, to stop on a cycle.
fn resolve(
  scope: Scope,
  type_: glance.Type,
  expanding: List(String),
) -> Result(ir.Type, List(Diagnostic)) {
  case type_ {
    glance.NamedType(location:, name:, module: Some(qualifier), parameters:) ->
      case find_import_by_qualifier(scope, qualifier) {
        Ok(import_) ->
          builtin(scope, import_.module, name, parameters, location, expanding)
        Error(Nil) ->
          Error([
            Diagnostic(
              Some(location),
              "no imported module is named `" <> qualifier <> "`",
            ),
          ])
      }

    glance.NamedType(location:, name:, module: None, parameters:) ->
      resolve_unqualified(scope, location, name, parameters, expanding)

    glance.TupleType(location:, elements: []) ->
      Error([
        Diagnostic(
          Some(location),
          "the empty tuple `#()` cannot cross the NIF boundary; use `Nil`",
        ),
      ])
    glance.TupleType(elements:, ..) ->
      elements
      |> list.map(resolve(scope, _, expanding))
      |> collect
      |> result.map(ir.Tuple)

    glance.FunctionType(location:, ..) ->
      Error([
        Diagnostic(Some(location), "functions cannot cross the NIF boundary"),
      ])
    glance.VariableType(location:, name:) ->
      Error([
        Diagnostic(
          Some(location),
          "type variable `"
            <> name
            <> "`: NIF signatures must use concrete types",
        ),
      ])
    glance.HoleType(location:, ..) ->
      Error([
        Diagnostic(Some(location), "NIF signatures cannot contain type holes"),
      ])
  }
}

fn resolve_unqualified(
  scope: Scope,
  location: glance.Span,
  name: String,
  parameters: List(glance.Type),
  expanding: List(String),
) -> Result(ir.Type, List(Diagnostic)) {
  case dict.get(scope.custom_types, name), dict.get(scope.aliases, name) {
    Ok(custom_type), _ ->
      case custom_type.parameters, parameters {
        [], [] -> Ok(ir.Named(name))
        _, _ ->
          Error([
            Diagnostic(
              Some(location),
              "`"
                <> name
                <> "` has type parameters, but NIF types must be concrete",
            ),
          ])
      }

    _, Ok(alias) ->
      case alias.parameters, list.contains(expanding, name) {
        [], False -> resolve(scope, alias.aliased, [name, ..expanding])
        [], True ->
          Error([
            Diagnostic(
              Some(location),
              "type alias `" <> name <> "` refers to itself",
            ),
          ])
        _, _ ->
          Error([
            Diagnostic(
              Some(location),
              "type alias `"
                <> name
                <> "` has type parameters, but NIF types must be concrete",
            ),
          ])
      }

    Error(Nil), Error(Nil) ->
      case find_unqualified_import(scope, name) {
        Ok(#(module, original)) ->
          builtin(scope, module, original, parameters, location, expanding)
        Error(Nil) ->
          builtin(scope, "gleam", name, parameters, location, expanding)
      }
  }
}

fn find_import_by_qualifier(
  scope: Scope,
  qualifier: String,
) -> Result(glance.Import, Nil) {
  list.find(scope.imports, fn(import_) {
    let name = case import_.alias {
      Some(glance.Named(alias)) -> alias
      Some(glance.Discarded(_)) -> ""
      None ->
        import_.module
        |> string.split("/")
        |> list.last
        |> result.unwrap(import_.module)
    }
    name == qualifier
  })
}

fn find_unqualified_import(
  scope: Scope,
  name: String,
) -> Result(#(String, String), Nil) {
  list.find_map(scope.imports, fn(import_) {
    list.find_map(import_.unqualified_types, fn(unqualified) {
      case option.unwrap(unqualified.alias, unqualified.name) == name {
        True -> Ok(#(import_.module, unqualified.name))
        False -> Error(Nil)
      }
    })
  })
}

/// Resolves a type that Gleam or its standard library defines.
fn builtin(
  scope: Scope,
  module: String,
  name: String,
  parameters: List(glance.Type),
  location: glance.Span,
  expanding: List(String),
) -> Result(ir.Type, List(Diagnostic)) {
  let resolve = resolve(scope, _, expanding)
  case module, name, parameters {
    "gleam", "Int", [] -> Ok(ir.Int)
    "gleam", "Float", [] -> Ok(ir.Float)
    "gleam", "Bool", [] -> Ok(ir.Bool)
    "gleam", "String", [] -> Ok(ir.String)
    "gleam", "BitArray", [] -> Ok(ir.BitArray)
    "gleam", "UtfCodepoint", [] -> Ok(ir.UtfCodepoint)
    "gleam", "Nil", [] -> Ok(ir.Nil)
    "gleam", "List", [element] -> result.map(resolve(element), ir.List)
    "gleam/option", "Option", [value] -> result.map(resolve(value), ir.Option)
    "gleam", "Result", [ok, error] ->
      both(resolve(ok), resolve(error))
      |> result.map(fn(t) { ir.Result(t.0, t.1) })
    "gleam/dict", "Dict", [key, value] ->
      both(resolve(key), resolve(value))
      |> result.map(fn(t) { ir.Dict(t.0, t.1) })
    _, _, _ -> {
      let qualified = case module {
        "gleam" -> name
        _ -> module <> "." <> name
      }
      Error([
        Diagnostic(
          Some(location),
          "`"
            <> qualified
            <> "` cannot cross the NIF boundary. NIFs can use Int, Float, "
            <> "Bool, String, BitArray, UtfCodepoint, Nil, List, tuples, "
            <> "Result, Option, Dict, and custom types defined in this module.",
        ),
      ])
    }
  }
}

/// Finds every custom type the functions use, directly or through other
/// types, in the order the module defines them.
fn read_types(
  scope: Scope,
  functions: List(ir.Function),
) -> Result(List(ir.TypeDef), List(Diagnostic)) {
  let roots =
    list.flat_map(functions, fn(function) {
      [function.return, ..list.map(function.parameters, fn(p) { p.type_ })]
    })
    |> list.flat_map(ir.referenced_types)
  use found <- result.map(walk_types(scope, roots, set.new(), []))
  found
  |> list.sort(fn(a, b) { int.compare(a.0.location.start, b.0.location.start) })
  |> list.map(fn(pair) { pair.1 })
}

fn walk_types(
  scope: Scope,
  queue: List(String),
  seen: Set(String),
  found: List(#(glance.CustomType, ir.TypeDef)),
) -> Result(List(#(glance.CustomType, ir.TypeDef)), List(Diagnostic)) {
  case queue {
    [] -> Ok(found)
    [name, ..queue] ->
      case set.contains(seen, name) {
        True -> walk_types(scope, queue, seen, found)
        False -> {
          let assert Ok(custom_type) = dict.get(scope.custom_types, name)
          use definition <- result.try(read_custom_type(scope, custom_type))
          let referenced = case definition {
            ir.Custom(variants:, ..) ->
              list.flat_map(variants, fn(variant) {
                list.flat_map(variant.fields, fn(f) {
                  ir.referenced_types(f.type_)
                })
              })
            ir.Resource(..) -> []
          }
          walk_types(
            scope,
            list.append(queue, referenced),
            set.insert(seen, name),
            [#(custom_type, definition), ..found],
          )
        }
      }
  }
}

fn read_custom_type(
  scope: Scope,
  custom_type: glance.CustomType,
) -> Result(ir.TypeDef, List(Diagnostic)) {
  case custom_type.variants {
    [] -> Ok(ir.Resource(custom_type.name))
    variants ->
      variants
      |> list.map(fn(variant) {
        variant.fields
        |> list.map(fn(field) {
          case field {
            glance.LabelledVariantField(item:, label:) ->
              resolve(scope, item, [])
              |> result.map(ir.Field(Some(label), _))
            glance.UnlabelledVariantField(item:) ->
              resolve(scope, item, []) |> result.map(ir.Field(None, _))
          }
        })
        |> collect
        |> result.map(fn(fields) {
          ir.Variant(
            name: variant.name,
            tag: naming.constructor_tag(variant.name),
            fields:,
          )
        })
      })
      |> collect
      |> result.map(ir.Custom(custom_type.name, _))
  }
}

// Helpers ---------------------------------------------------------------------

/// Combines results, keeping every diagnostic rather than only the first.
fn collect(
  results: List(Result(a, List(Diagnostic))),
) -> Result(List(a), List(Diagnostic)) {
  let #(values, errors) = result.partition(results)
  case errors {
    [] -> Ok(list.reverse(values))
    _ -> Error(errors |> list.reverse |> list.flatten)
  }
}

fn both(
  a: Result(a, List(Diagnostic)),
  b: Result(b, List(Diagnostic)),
) -> Result(#(a, b), List(Diagnostic)) {
  case a, b {
    Ok(a), Ok(b) -> Ok(#(a, b))
    Error(a), Error(b) -> Error(list.append(a, b))
    Error(errors), _ | _, Error(errors) -> Error(errors)
  }
}
