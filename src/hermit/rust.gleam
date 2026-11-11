//// Generates a Rustler crate for a NIF library.
////
//// The crate has two kinds of files. `src/generated.rs` holds the Rust
//// versions of the library's types, the conversions between them and BEAM
//// terms, and the `#[rustler::nif]` entry points; hermit rewrites it every
//// time. `Cargo.toml` and `src/lib.rs` are scaffolds that hermit writes once
//// and the user then owns: `lib.rs` is where the NIFs are implemented, as
//// plain Rust functions over plain Rust types.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import hermit/ir
import hermit/naming
import tom

/// The Rustler release generated crates depend on.
pub const rustler_version = "0.39"

/// The name of the Rust crate and of the library it builds.
pub fn crate_name(library: ir.Library) -> String {
  naming.crate_name(library.erlang_module)
}

// Checks ----------------------------------------------------------------------

/// Reports what the library uses that Rust cannot express.
pub fn check(library: ir.Library) -> Result(Nil, List(String)) {
  let analysis = analyze(library)
  let reserved =
    list.flat_map(library.types, fn(definition) {
      let name = ir.type_def_name(definition)
      let type_problem = case list.contains(reserved_type_names, name) {
        True -> [
          "type `"
          <> name
          <> "` clashes with a name the generated Rust code uses; rename it",
        ]
        False -> []
      }
      let variant_problems = case definition {
        ir.Custom(variants:, ..) ->
          variants
          |> list.filter(fn(variant) { variant.name == "Self" })
          |> list.map(fn(_) {
            "constructor `Self` of `"
            <> name
            <> "` is a Rust keyword; rename it"
          })
        ir.Resource(..) -> []
      }
      list.append(type_problem, variant_problems)
    })
  let keys =
    list.flat_map(all_type_uses(library), fn(use_) {
      let #(place, type_) = use_
      unhashable_keys(analysis, type_)
      |> list.map(fn(key) {
        place
        <> " uses `Dict` with key type "
        <> describe_type(key)
        <> ", which Rust cannot hash. Dict keys cannot contain Float, Dict, "
        <> "or resource types."
      })
    })
  case list.append(reserved, keys) {
    [] -> Ok(Nil)
    problems -> Error(list.unique(problems))
  }
}

/// Names the generated code refers to unqualified. A Gleam type with one of
/// these names would shadow them.
const reserved_type_names = [
  "BitArray", "Box", "Env", "Err", "From", "FromGleam", "HashMap", "Into",
  "IntoGleam", "Iterator", "NifResult", "None", "Ok", "Option", "ResourceArc",
  "Result", "Self", "Sized", "Some", "String", "Term", "Vec",
]

fn all_type_uses(library: ir.Library) -> List(#(String, ir.Type)) {
  let in_functions =
    list.flat_map(library.functions, fn(function) {
      let place = "function `" <> function.name <> "`"
      [
        #(place, function.return),
        ..list.map(function.parameters, fn(p) { #(place, p.type_) })
      ]
    })
  let in_types =
    list.flat_map(library.types, fn(definition) {
      case definition {
        ir.Custom(name:, variants:) ->
          list.flat_map(variants, fn(variant) {
            list.map(variant.fields, fn(field) {
              #("type `" <> name <> "`", field.type_)
            })
          })
        ir.Resource(..) -> []
      }
    })
  list.append(in_functions, in_types)
}

fn unhashable_keys(analysis: Analysis, type_: ir.Type) -> List(ir.Type) {
  case type_ {
    ir.Dict(key, value) -> {
      let nested =
        list.append(
          unhashable_keys(analysis, key),
          unhashable_keys(analysis, value),
        )
      case is_hashable(analysis, key) {
        True -> nested
        False -> [key, ..nested]
      }
    }
    ir.List(t) | ir.Option(t) -> unhashable_keys(analysis, t)
    ir.Result(a, b) ->
      list.append(unhashable_keys(analysis, a), unhashable_keys(analysis, b))
    ir.Tuple(elements) -> list.flat_map(elements, unhashable_keys(analysis, _))
    ir.Int
    | ir.Float
    | ir.Bool
    | ir.String
    | ir.BitArray
    | ir.UtfCodepoint
    | ir.Nil
    | ir.Named(_) -> []
  }
}

fn describe_type(type_: ir.Type) -> String {
  case type_ {
    ir.Int -> "Int"
    ir.Float -> "Float"
    ir.Bool -> "Bool"
    ir.String -> "String"
    ir.BitArray -> "BitArray"
    ir.UtfCodepoint -> "UtfCodepoint"
    ir.Nil -> "Nil"
    ir.Named(name) -> name
    ir.List(t) -> "List(" <> describe_type(t) <> ")"
    ir.Option(t) -> "Option(" <> describe_type(t) <> ")"
    ir.Result(a, b) ->
      "Result(" <> describe_type(a) <> ", " <> describe_type(b) <> ")"
    ir.Dict(a, b) ->
      "Dict(" <> describe_type(a) <> ", " <> describe_type(b) <> ")"
    ir.Tuple(elements) ->
      "#(" <> list.map(elements, describe_type) |> string.join(", ") <> ")"
  }
}

// Analysis --------------------------------------------------------------------

/// Facts about the library's types that decide how they look in Rust.
type Analysis {
  Analysis(
    resources: Set(String),
    /// Custom types that hold a resource, which has no `Debug` or `PartialEq`.
    with_resources: Set(String),
    /// Custom types that cannot derive `Eq` and `Hash`.
    unhashable: Set(String),
    /// For each custom type, the custom types it contains without a `Vec` or
    /// `HashMap` in between. A cycle here needs a `Box` to have a size.
    inline: Dict(String, List(String)),
  )
}

fn analyze(library: ir.Library) -> Analysis {
  let resources =
    library.types
    |> list.filter_map(fn(definition) {
      case definition {
        ir.Resource(name:) -> Ok(name)
        ir.Custom(..) -> Error(Nil)
      }
    })
    |> set.from_list
  let fields =
    list.filter_map(library.types, fn(definition) {
      case definition {
        ir.Custom(name:, variants:) ->
          Ok(#(
            name,
            list.flat_map(variants, fn(v) {
              list.map(v.fields, fn(f) { f.type_ })
            }),
          ))
        ir.Resource(..) -> Error(Nil)
      }
    })
  let is_resource = fn(type_) {
    case type_ {
      ir.Named(name) -> set.contains(resources, name)
      _ -> False
    }
  }
  let with_resources = mark(fields, set.new(), is_resource)
  let unhashable =
    mark(fields, set.new(), fn(type_) {
      case type_ {
        ir.Float | ir.Dict(..) -> True
        _ -> is_resource(type_)
      }
    })
  let inline =
    fields
    |> list.map(fn(pair) { #(pair.0, list.flat_map(pair.1, inline_references)) })
    |> dict.from_list
  Analysis(resources:, with_resources:, unhashable:, inline:)
}

/// Marks every custom type with a field that, at any depth, satisfies
/// `bad` or refers to a marked type. Repeats until nothing changes, which
/// handles recursive types.
fn mark(
  fields: List(#(String, List(ir.Type))),
  marked: Set(String),
  bad: fn(ir.Type) -> Bool,
) -> Set(String) {
  let next =
    list.fold(fields, marked, fn(marked, pair) {
      case list.any(pair.1, contains(_, marked, bad)) {
        True -> set.insert(marked, pair.0)
        False -> marked
      }
    })
  case set.size(next) == set.size(marked) {
    True -> marked
    False -> mark(fields, next, bad)
  }
}

fn contains(
  type_: ir.Type,
  marked: Set(String),
  bad: fn(ir.Type) -> Bool,
) -> Bool {
  bad(type_)
  || case type_ {
    ir.Named(name) -> set.contains(marked, name)
    ir.List(t) | ir.Option(t) -> contains(t, marked, bad)
    ir.Result(a, b) | ir.Dict(a, b) ->
      contains(a, marked, bad) || contains(b, marked, bad)
    ir.Tuple(elements) -> list.any(elements, contains(_, marked, bad))
    ir.Int
    | ir.Float
    | ir.Bool
    | ir.String
    | ir.BitArray
    | ir.UtfCodepoint
    | ir.Nil -> False
  }
}

fn is_hashable(analysis: Analysis, type_: ir.Type) -> Bool {
  !contains(type_, analysis.unhashable, fn(type_) {
    case type_ {
      ir.Float | ir.Dict(..) -> True
      ir.Named(name) -> set.contains(analysis.resources, name)
      _ -> False
    }
  })
}

fn inline_references(type_: ir.Type) -> List(String) {
  case type_ {
    ir.Named(name) -> [name]
    ir.Option(t) -> inline_references(t)
    ir.Result(a, b) -> list.append(inline_references(a), inline_references(b))
    ir.Tuple(elements) -> list.flat_map(elements, inline_references)
    ir.List(_)
    | ir.Dict(..)
    | ir.Int
    | ir.Float
    | ir.Bool
    | ir.String
    | ir.BitArray
    | ir.UtfCodepoint
    | ir.Nil -> []
  }
}

/// Whether `from` contains `to` inline, possibly through other types.
fn reaches(analysis: Analysis, from: String, to: String) -> Bool {
  do_reaches(analysis, [from], to, set.new())
}

fn do_reaches(
  analysis: Analysis,
  queue: List(String),
  to: String,
  seen: Set(String),
) -> Bool {
  case queue {
    [] -> False
    [name, ..] if name == to -> True
    [name, ..queue] ->
      case set.contains(seen, name) {
        True -> do_reaches(analysis, queue, to, seen)
        False -> {
          let next = dict.get(analysis.inline, name) |> result.unwrap([])
          do_reaches(
            analysis,
            list.append(queue, next),
            to,
            set.insert(seen, name),
          )
        }
      }
  }
}

// Rust types ------------------------------------------------------------------

/// The Rust type for an IR type. `container` names the custom type whose
/// field this is, so that references back to it can be boxed.
fn rust_type(
  analysis: Analysis,
  type_: ir.Type,
  container: Option(String),
) -> String {
  case type_ {
    ir.Int -> "i64"
    ir.Float -> "f64"
    ir.Bool -> "bool"
    ir.String -> "String"
    ir.BitArray -> "BitArray"
    ir.UtfCodepoint -> "char"
    ir.Nil -> "()"
    ir.List(t) -> "Vec<" <> rust_type(analysis, t, None) <> ">"
    ir.Dict(k, v) ->
      "HashMap<"
      <> rust_type(analysis, k, None)
      <> ", "
      <> rust_type(analysis, v, None)
      <> ">"
    ir.Option(t) -> "Option<" <> rust_type(analysis, t, container) <> ">"
    ir.Result(a, b) ->
      "Result<"
      <> rust_type(analysis, a, container)
      <> ", "
      <> rust_type(analysis, b, container)
      <> ">"
    ir.Tuple(elements) ->
      rust_tuple(list.map(elements, rust_type(analysis, _, container)))
    ir.Named(name) ->
      case set.contains(analysis.resources, name), container {
        True, _ -> "ResourceArc<" <> name <> ">"
        False, Some(container) ->
          case reaches(analysis, name, container) {
            True -> "Box<" <> name <> ">"
            False -> name
          }
        False, None -> name
      }
  }
}

fn tuple_arities(library: ir.Library) -> List(Int) {
  all_type_uses(library)
  |> list.flat_map(fn(use_) { arities(use_.1) })
  |> list.unique
  |> list.sort(int.compare)
}

fn arities(type_: ir.Type) -> List(Int) {
  case type_ {
    ir.Tuple(elements) -> [
      list.length(elements),
      ..list.flat_map(elements, arities)
    ]
    ir.List(t) | ir.Option(t) -> arities(t)
    ir.Result(a, b) | ir.Dict(a, b) -> list.append(arities(a), arities(b))
    ir.Int
    | ir.Float
    | ir.Bool
    | ir.String
    | ir.BitArray
    | ir.UtfCodepoint
    | ir.Nil
    | ir.Named(_) -> []
  }
}

// generated.rs ----------------------------------------------------------------

/// The contents of `src/generated.rs`.
pub fn generated_rs(library: ir.Library) -> String {
  let analysis = analyze(library)
  let customs =
    list.filter_map(library.types, fn(definition) {
      case definition {
        ir.Custom(name:, variants:) -> Ok(#(name, variants))
        ir.Resource(..) -> Error(Nil)
      }
    })
  [
    header(library),
    runtime_prelude,
    section("Types"),
    ..list.map(customs, fn(custom) {
      type_declaration(analysis, library, custom.0, custom.1)
    })
  ]
  |> list.append([
    section("Atoms"),
    atoms_module(customs),
    section("Conversions"),
    runtime_conversions,
    ..list.map(tuple_arities(library), tuple_impl)
  ])
  |> list.append(
    list.map(customs, fn(custom) { from_gleam_impl(custom.0, custom.1) }),
  )
  |> list.append(
    list.map(customs, fn(custom) { into_gleam_impl(custom.0, custom.1) }),
  )
  |> list.append([
    section("NIFs"),
    nifs_module(library),
    "rustler::init!(" <> rust_string(library.erlang_module) <> ");\n",
  ])
  |> string.join("\n")
}

fn header(library: ir.Library) -> String {
  "// @generated by hermit from "
  <> library.source
  <> ". Do not edit this file:\n"
  <> "// change the Gleam module and run `gleam run -m hermit generate`.\n\n"
  <> "#![allow(dead_code, unused_imports, clippy::all)]\n"
}

fn section(title: String) -> String {
  let rule = string.repeat("-", 76 - string.length(title))
  "// " <> title <> " " <> rule <> "\n"
}

const runtime_prelude =
  "use rustler::types::tuple::{get_tuple, make_tuple};
use rustler::Encoder as _;
use rustler::{Env, NifResult, Term};

pub use rustler::ResourceArc;
pub use std::collections::HashMap;

/// The bytes of a Gleam `BitArray`. Only byte-aligned bit arrays cross the
/// NIF boundary, and the bytes are copied in both directions.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct BitArray(pub Vec<u8>);

impl std::ops::Deref for BitArray {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        &self.0
    }
}

impl From<Vec<u8>> for BitArray {
    fn from(bytes: Vec<u8>) -> Self {
        BitArray(bytes)
    }
}

impl From<&[u8]> for BitArray {
    fn from(bytes: &[u8]) -> Self {
        BitArray(bytes.to_vec())
    }
}

impl From<BitArray> for Vec<u8> {
    fn from(bits: BitArray) -> Self {
        bits.0
    }
}
"

fn type_declaration(
  analysis: Analysis,
  library: ir.Library,
  name: String,
  variants: List(ir.Variant),
) -> String {
  let fieldless = list.all(variants, fn(v) { v.fields == [] })
  let with_resources = set.contains(analysis.with_resources, name)
  let derives =
    [
      #("Debug", !with_resources),
      #("Clone", True),
      #("Copy", fieldless),
      #("PartialEq", !with_resources),
      #("Eq", !set.contains(analysis.unhashable, name)),
      #("Hash", !set.contains(analysis.unhashable, name)),
    ]
    |> list.filter(fn(trait_) { trait_.1 })
    |> list.map(fn(trait_) { trait_.0 })
  let doc =
    "/// The Gleam type `"
    <> name
    <> "` from `"
    <> library.source
    <> "`.\n#[derive("
    <> string.join(derives, ", ")
    <> ")]\n"
  case variants {
    [variant] ->
      doc
      <> "pub struct "
      <> name
      <> struct_body(analysis, name, variant.fields)
      <> "\n"
    _ ->
      doc
      <> "pub enum "
      <> name
      <> " {\n"
      <> list.map(variants, fn(variant) {
        "    "
        <> variant.name
        <> variant_body(analysis, name, variant.fields)
        <> ",\n"
      })
      |> string.concat
      <> "}\n"
  }
}

fn struct_body(
  analysis: Analysis,
  container: String,
  fields: List(ir.Field),
) -> String {
  case field_style(fields) {
    NoFields -> ";"
    Positional ->
      "("
      <> list.map(fields, fn(f) {
        "pub " <> rust_type(analysis, f.type_, Some(container))
      })
      |> string.join(", ")
      <> ");"
    Named ->
      " {\n"
      <> list.index_map(fields, fn(f, index) {
        "    pub "
        <> field_name(f, index)
        <> ": "
        <> rust_type(analysis, f.type_, Some(container))
        <> ",\n"
      })
      |> string.concat
      <> "}"
  }
}

fn variant_body(
  analysis: Analysis,
  container: String,
  fields: List(ir.Field),
) -> String {
  case field_style(fields) {
    NoFields -> ""
    Positional ->
      "("
      <> list.map(fields, fn(f) {
        rust_type(analysis, f.type_, Some(container))
      })
      |> string.join(", ")
      <> ")"
    Named ->
      " { "
      <> list.index_map(fields, fn(f, index) {
        field_name(f, index)
        <> ": "
        <> rust_type(analysis, f.type_, Some(container))
      })
      |> string.join(", ")
      <> " }"
  }
}

type FieldStyle {
  NoFields
  Positional
  Named
}

/// Constructors with only unlabeled fields become tuple structs or tuple
/// variants. Any label makes every field named; unlabeled fields are then
/// named after their position.
fn field_style(fields: List(ir.Field)) -> FieldStyle {
  case fields, list.any(fields, fn(f) { option.is_some(f.label) }) {
    [], _ -> NoFields
    _, False -> Positional
    _, True -> Named
  }
}

fn field_name(field: ir.Field, index: Int) -> String {
  case field.label {
    Some(label) -> naming.rust_identifier(label)
    None -> "field" <> int.to_string(index)
  }
}

fn atoms_module(customs: List(#(String, List(ir.Variant)))) -> String {
  let tags =
    customs
    |> list.flat_map(fn(custom) { list.map(custom.1, fn(v) { v.tag }) })
    |> list.append(["error", "nil", "none", "ok", "some"], _)
    |> list.unique
    |> list.sort(string.compare)
  "mod atoms {\n    rustler::atoms! {\n"
  <> list.map(tags, fn(tag) { "        " <> atom_entry(tag) <> ",\n" })
  |> string.concat
  <> "    }\n}\n"
}

fn atom_entry(tag: String) -> String {
  case naming.rust_identifier(tag) {
    identifier if identifier == tag -> tag
    identifier -> identifier <> " = " <> rust_string(tag)
  }
}

fn atom(tag: String) -> String {
  "atoms::" <> naming.rust_identifier(tag) <> "()"
}

const runtime_conversions =
  "/// Decodes a value from the term Gleam uses for it.
pub trait FromGleam<'a>: Sized {
    fn from_gleam(term: Term<'a>) -> NifResult<Self>;
}

/// Encodes a value as the term Gleam uses for it.
pub trait IntoGleam {
    fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a>;
}

/// Splits a custom type value into its constructor's tag and fields. A
/// constructor without fields is an atom; one with fields is a tuple whose
/// first element is the tag.
fn constructor<'a>(term: Term<'a>) -> NifResult<(rustler::Atom, Vec<Term<'a>>)> {
    if let Ok(tag) = term.decode::<rustler::Atom>() {
        return Ok((tag, Vec::new()));
    }
    let mut elements = get_tuple(term)?;
    if elements.is_empty() {
        return Err(rustler::Error::BadArg);
    }
    let tag = elements.remove(0).decode::<rustler::Atom>()?;
    Ok((tag, elements))
}

/// Builds the tuple for a constructor with fields.
fn record<'a>(env: Env<'a>, tag: rustler::Atom, fields: &[Term<'a>]) -> Term<'a> {
    let mut elements = Vec::with_capacity(fields.len() + 1);
    elements.push(tag.encode(env));
    elements.extend_from_slice(fields);
    make_tuple(env, &elements)
}

macro_rules! same_as_rustler {
    ($($t:ty),*) => {
        $(
            impl<'a> FromGleam<'a> for $t {
                fn from_gleam(term: Term<'a>) -> NifResult<Self> {
                    term.decode()
                }
            }

            impl IntoGleam for $t {
                fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a> {
                    self.encode(env)
                }
            }
        )*
    };
}

same_as_rustler!(i64, bool, String);

impl<'a> FromGleam<'a> for f64 {
    fn from_gleam(term: Term<'a>) -> NifResult<Self> {
        term.decode()
    }
}

impl IntoGleam for f64 {
    fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a> {
        // The BEAM has no NaN or infinity, and Rustler encodes them as a badarg
        // exception that is only valid as a NIF's whole result. A panic is
        // well defined anywhere: the NIF raises `nif_panicked`.
        assert!(self.is_finite(), \"Gleam floats must be finite, not {self}\");
        self.encode(env)
    }
}

impl<'a> FromGleam<'a> for () {
    fn from_gleam(term: Term<'a>) -> NifResult<Self> {
        if atoms::nil() == term {
            Ok(())
        } else {
            Err(rustler::Error::BadArg)
        }
    }
}

impl IntoGleam for () {
    fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a> {
        atoms::nil().encode(env)
    }
}

impl<'a> FromGleam<'a> for char {
    fn from_gleam(term: Term<'a>) -> NifResult<Self> {
        char::from_u32(term.decode()?).ok_or(rustler::Error::BadArg)
    }
}

impl IntoGleam for char {
    fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a> {
        (self as u32).encode(env)
    }
}

impl<'a> FromGleam<'a> for BitArray {
    fn from_gleam(term: Term<'a>) -> NifResult<Self> {
        let binary = rustler::Binary::from_term(term)?;
        Ok(BitArray(binary.as_slice().to_vec()))
    }
}

impl IntoGleam for BitArray {
    fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a> {
        rustler::NewBinary::from_slice(env, &self.0).into()
    }
}

impl<'a, T: FromGleam<'a>> FromGleam<'a> for Vec<T> {
    fn from_gleam(term: Term<'a>) -> NifResult<Self> {
        term.decode::<rustler::ListIterator<'a>>()?
            .map(T::from_gleam)
            .collect()
    }
}

impl<T: IntoGleam> IntoGleam for Vec<T> {
    fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a> {
        let elements: Vec<Term<'a>> = self.into_iter().map(|e| e.into_gleam(env)).collect();
        elements.encode(env)
    }
}

impl<'a, T: FromGleam<'a>> FromGleam<'a> for Option<T> {
    fn from_gleam(term: Term<'a>) -> NifResult<Self> {
        match constructor(term)? {
            (tag, fields) if tag == atoms::none() && fields.is_empty() => Ok(None),
            (tag, fields) if tag == atoms::some() && fields.len() == 1 => {
                Ok(Some(T::from_gleam(fields[0])?))
            }
            _ => Err(rustler::Error::BadArg),
        }
    }
}

impl<T: IntoGleam> IntoGleam for Option<T> {
    fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a> {
        match self {
            Some(value) => record(env, atoms::some(), &[value.into_gleam(env)]),
            None => atoms::none().encode(env),
        }
    }
}

impl<'a, T: FromGleam<'a>, E: FromGleam<'a>> FromGleam<'a> for Result<T, E> {
    fn from_gleam(term: Term<'a>) -> NifResult<Self> {
        match constructor(term)? {
            (tag, fields) if tag == atoms::ok() && fields.len() == 1 => {
                Ok(Ok(T::from_gleam(fields[0])?))
            }
            (tag, fields) if tag == atoms::error() && fields.len() == 1 => {
                Ok(Err(E::from_gleam(fields[0])?))
            }
            _ => Err(rustler::Error::BadArg),
        }
    }
}

impl<T: IntoGleam, E: IntoGleam> IntoGleam for Result<T, E> {
    fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a> {
        match self {
            Ok(value) => record(env, atoms::ok(), &[value.into_gleam(env)]),
            Err(reason) => record(env, atoms::error(), &[reason.into_gleam(env)]),
        }
    }
}

impl<'a, K, V> FromGleam<'a> for HashMap<K, V>
where
    K: FromGleam<'a> + Eq + std::hash::Hash,
    V: FromGleam<'a>,
{
    fn from_gleam(term: Term<'a>) -> NifResult<Self> {
        rustler::MapIterator::new(term)
            .ok_or(rustler::Error::BadArg)?
            .map(|(key, value)| Ok((K::from_gleam(key)?, V::from_gleam(value)?)))
            .collect()
    }
}

impl<K: IntoGleam, V: IntoGleam> IntoGleam for HashMap<K, V> {
    fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a> {
        let (keys, values): (Vec<Term<'a>>, Vec<Term<'a>>) = self
            .into_iter()
            .map(|(key, value)| (key.into_gleam(env), value.into_gleam(env)))
            .unzip();
        Term::map_from_term_arrays(env, &keys, &values)
            .expect(\"distinct keys encode to distinct terms\")
    }
}

impl<'a, T: FromGleam<'a>> FromGleam<'a> for Box<T> {
    fn from_gleam(term: Term<'a>) -> NifResult<Self> {
        T::from_gleam(term).map(Box::new)
    }
}

impl<T: IntoGleam> IntoGleam for Box<T> {
    fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a> {
        (*self).into_gleam(env)
    }
}

impl<'a, T: rustler::Resource> FromGleam<'a> for ResourceArc<T> {
    fn from_gleam(term: Term<'a>) -> NifResult<Self> {
        term.decode()
    }
}

impl<T: rustler::Resource> IntoGleam for ResourceArc<T> {
    fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a> {
        self.encode(env)
    }
}
"

fn tuple_impl(arity: Int) -> String {
  let indexes = list.repeat(Nil, arity) |> list.index_map(fn(_, i) { i })
  let params = list.map(indexes, fn(i) { "T" <> int.to_string(i) })
  let decode_bounds =
    list.map(params, fn(p) { p <> ": FromGleam<'a>" }) |> string.join(", ")
  let encode_bounds =
    list.map(params, fn(p) { p <> ": IntoGleam" }) |> string.join(", ")
  let decoded =
    list.map(indexes, fn(i) {
      "T"
      <> int.to_string(i)
      <> "::from_gleam(elements["
      <> int.to_string(i)
      <> "])?"
    })
  let encoded =
    list.map(indexes, fn(i) {
      "self." <> int.to_string(i) <> ".into_gleam(env)"
    })
  "impl<'a, "
  <> decode_bounds
  <> "> FromGleam<'a> for "
  <> rust_tuple(params)
  <> " {
    fn from_gleam(term: Term<'a>) -> NifResult<Self> {
        let elements = get_tuple(term)?;
        if elements.len() != "
  <> int.to_string(arity)
  <> " {
            return Err(rustler::Error::BadArg);
        }
        Ok("
  <> rust_tuple(decoded)
  <> ")
    }
}

impl<"
  <> encode_bounds
  <> "> IntoGleam for "
  <> rust_tuple(params)
  <> " {
    fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a> {
        make_tuple(env, &["
  <> string.join(encoded, ", ")
  <> "])
    }
}
"
}

/// Rust tuple syntax, which needs a trailing comma for a single element.
fn rust_tuple(elements: List(String)) -> String {
  case elements {
    [single] -> "(" <> single <> ",)"
    _ -> "(" <> string.join(elements, ", ") <> ")"
  }
}

fn variant_path(
  name: String,
  variants: List(ir.Variant),
  variant: ir.Variant,
) -> String {
  case variants {
    [_] -> name
    _ -> name <> "::" <> variant.name
  }
}

/// A pattern that binds a constructor's fields to `f0`, `f1`, and so on.
fn constructor_pattern(path: String, fields: List(ir.Field)) -> String {
  let binding = fn(i) { "f" <> int.to_string(i) }
  case field_style(fields) {
    NoFields -> path
    Positional ->
      path
      <> "("
      <> list.index_map(fields, fn(_, i) { binding(i) }) |> string.join(", ")
      <> ")"
    Named ->
      path
      <> " { "
      <> list.index_map(fields, fn(f, i) {
        field_name(f, i) <> ": " <> binding(i)
      })
      |> string.join(", ")
      <> " }"
  }
}

/// An expression that builds a constructor from the decoded `fields`, one
/// field per line, for a match arm at the given indentation.
fn constructor_value(
  path: String,
  fields: List(ir.Field),
  indent: String,
) -> String {
  let lines = fn(items) {
    "\n"
    <> list.map(items, fn(item) { indent <> "    " <> item <> ",\n" })
    |> string.concat
    <> indent
  }
  let decode = fn(i) {
    "FromGleam::from_gleam(fields[" <> int.to_string(i) <> "])?"
  }
  case field_style(fields) {
    NoFields -> path
    Positional ->
      path
      <> "("
      <> lines(list.index_map(fields, fn(_, i) { decode(i) }))
      <> ")"
    Named ->
      path
      <> " {"
      <> lines(
        list.index_map(fields, fn(f, i) {
          field_name(f, i) <> ": " <> decode(i)
        }),
      )
      <> "}"
  }
}

fn encode_constructor(variant: ir.Variant) -> String {
  case variant.fields {
    [] -> atom(variant.tag) <> ".encode(env)"
    fields ->
      "record(env, "
      <> atom(variant.tag)
      <> ", &["
      <> list.index_map(fields, fn(_, i) {
        "f" <> int.to_string(i) <> ".into_gleam(env)"
      })
      |> string.join(", ")
      <> "])"
  }
}

fn from_gleam_impl(name: String, variants: List(ir.Variant)) -> String {
  let indent = "            "
  let arms =
    list.map(variants, fn(variant) {
      let guard = case list.length(variant.fields) {
        0 -> "fields.is_empty()"
        count -> "fields.len() == " <> int.to_string(count)
      }
      let path = variant_path(name, variants, variant)
      indent
      <> "(tag, fields) if tag == "
      <> atom(variant.tag)
      <> " && "
      <> guard
      <> " => Ok("
      <> constructor_value(path, variant.fields, indent)
      <> "),\n"
    })
  "impl<'a> FromGleam<'a> for " <> name <> " {
    fn from_gleam(term: Term<'a>) -> NifResult<Self> {
        match constructor(term)? {
" <> string.concat(arms) <> indent <> "_ => Err(rustler::Error::BadArg),
        }
    }
}
"
}

fn into_gleam_impl(name: String, variants: List(ir.Variant)) -> String {
  let body = case variants {
    [ir.Variant(fields: [], ..) as variant] ->
      "        " <> encode_constructor(variant) <> "\n"
    [variant] ->
      "        let "
      <> constructor_pattern(name, variant.fields)
      <> " = self;\n        "
      <> encode_constructor(variant)
      <> "\n"
    _ ->
      "        match self {\n"
      <> list.map(variants, fn(variant) {
        let pattern =
          constructor_pattern(
            variant_path(name, variants, variant),
            variant.fields,
          )
        case variant.fields {
          [] ->
            "            "
            <> pattern
            <> " => "
            <> encode_constructor(variant)
            <> ",\n"
          _ ->
            "            "
            <> pattern
            <> " => {\n                "
            <> encode_constructor(variant)
            <> "\n            }\n"
        }
      })
      |> string.concat
      <> "        }\n"
  }
  "impl IntoGleam for " <> name <> " {
    fn into_gleam<'a>(self, env: Env<'a>) -> Term<'a> {
" <> body <> "    }
}
"
}

fn nifs_module(library: ir.Library) -> String {
  "mod nifs {\n    use super::*;\n"
  <> list.map(library.functions, nif_function) |> string.concat
  <> "}\n"
}

fn nif_function(function: ir.Function) -> String {
  let arguments =
    list.index_map(function.parameters, fn(_, i) { "arg" <> int.to_string(i) })
  let attribute_options =
    [
      Ok("name = " <> rust_string(function.erlang_name)),
      case function.schedule {
        ir.Normal -> Error(Nil)
        ir.DirtyCpu -> Ok("schedule = \"DirtyCpu\"")
        ir.DirtyIo -> Ok("schedule = \"DirtyIo\"")
      },
    ]
    |> list.filter_map(fn(option) { option })
  let parameters =
    ["env: Env<'a>", ..list.map(arguments, fn(a) { a <> ": Term<'a>" })]
    |> string.join(", ")
  let rust_name = naming.rust_identifier(function.name)
  let decoded =
    list.map(arguments, fn(a) { "FromGleam::from_gleam(" <> a <> ")?" })
  let one_line =
    "crate::" <> rust_name <> "(" <> string.join(decoded, ", ") <> ")"
  let call = case
    string.length("        let result = " <> one_line <> ";") <= 100
  {
    True -> one_line
    False ->
      "crate::"
      <> rust_name
      <> "(\n"
      <> list.map(decoded, fn(d) { "            " <> d <> ",\n" })
      |> string.concat
      <> "        )"
  }
  "\n    #[rustler::nif(" <> string.join(attribute_options, ", ") <> ")]
    fn " <> rust_name <> "<'a>(" <> parameters <> ") -> NifResult<Term<'a>> {
        let result = " <> call <> ";
        Ok(result.into_gleam(env))
    }
"
}

fn rust_string(value: String) -> String {
  "\""
  <> value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  <> "\""
}

// Scaffolds -------------------------------------------------------------------

/// The contents of `Cargo.toml`, written once.
pub fn cargo_toml(library: ir.Library) -> String {
  "[package]
name = \"" <> crate_name(library) <> "\"
version = \"0.1.0\"
edition = \"2024\"
publish = false

[lib]
crate-type = [\"cdylib\"]

[dependencies]
rustler = \"" <> rustler_version <> "\"
"
}

/// Checks that a crate's `Cargo.toml` depends on the Rustler release series
/// that generated code is written for, `rustler_version`. Returns the crate's
/// version requirement if it selects another series. A requirement hermit
/// cannot compare, such as a range or a Git checkout, passes.
pub fn check_rustler_dependency(cargo_toml: String) -> Result(Nil, String) {
  let found = {
    use toml <- result.try(tom.parse(cargo_toml) |> result.replace_error(Nil))
    use requirement <- result.try(
      tom.get_string(toml, ["dependencies", "rustler"])
      |> result.lazy_or(fn() {
        tom.get_string(toml, ["dependencies", "rustler", "version"])
      })
      |> result.replace_error(Nil),
    )
    use series <- result.map(release_series(requirement))
    #(requirement, series)
  }
  case found {
    Ok(#(requirement, series)) ->
      case Ok(series) == release_series(rustler_version) {
        True -> Ok(Nil)
        False -> Error(requirement)
      }
    Error(Nil) -> Ok(Nil)
  }
}

/// The release series that a Cargo version requirement such as `0.39` or
/// `^0.39.1` selects from. Cargo treats the releases in a series as
/// compatible: `0.39.x` for a `0.` version, and `1.x.y` from `1.0` on. Fails
/// for a requirement that is not a single version.
fn release_series(requirement: String) -> Result(String, Nil) {
  let version = case string.trim(requirement) {
    "^" <> version | "=" <> version | "~" <> version ->
      string.trim_start(version)
    version -> version
  }
  case string.split(version, ".") |> list.map(int.parse) {
    [Ok(0), Ok(minor), ..] -> Ok("0." <> int.to_string(minor))
    [Ok(major), ..] if major > 0 -> Ok(int.to_string(major))
    _ -> Error(Nil)
  }
}

/// The contents of the crate's `.gitignore`, written once.
pub const gitignore = "/target\n"

/// The contents of `src/lib.rs`, written once: a stub for every resource and
/// NIF for the user to fill in.
pub fn lib_rs(library: ir.Library) -> String {
  "//! Rust implementations of the NIFs declared in `" <> library.source <> "`.
//!
//! Hermit created this file and never overwrites it, so it is yours to edit.
//! Each NIF is a plain Rust function over plain Rust types. The Rust versions
//! of the Gleam types, and the glue that converts them to and from BEAM terms,
//! are in `generated.rs`, which `gleam run -m hermit generate` rewrites.

#[rustfmt::skip]
mod generated;

#[allow(unused_imports)]
use generated::*;
" <> list.map(stubs(library), fn(stub) { "\n" <> stub }) |> string.concat
}

/// Rust stubs for the resources and NIFs of a library, keyed by the name
/// hermit looks for to decide whether the user has written them.
pub fn stubs(library: ir.Library) -> List(String) {
  list.append(
    list.map(resources(library), resource_stub),
    list.map(library.functions, function_stub(analyze(library), _)),
  )
}

/// The stubs whose items no Rust source in `sources` defines.
pub fn missing_stubs(
  library: ir.Library,
  sources: List(String),
) -> List(String) {
  let defines = fn(needle) { list.any(sources, string.contains(_, needle)) }
  let missing_resources =
    resources(library)
    |> list.filter(fn(name) { !defines("struct " <> name) })
    |> list.map(resource_stub)
  let analysis = analyze(library)
  let missing_functions =
    library.functions
    |> list.filter(fn(function) {
      let name = naming.rust_identifier(function.name)
      !defines("fn " <> name <> "(") && !defines("fn " <> name <> "<")
    })
    |> list.map(function_stub(analysis, _))
  list.append(missing_resources, missing_functions)
}

fn resources(library: ir.Library) -> List(String) {
  list.filter_map(library.types, fn(definition) {
    case definition {
      ir.Resource(name:) -> Ok(name)
      ir.Custom(..) -> Error(Nil)
    }
  })
}

fn resource_stub(name: String) -> String {
  "/// Backs the Gleam type `" <> name <> "`. The BEAM shares resources between
/// processes, so they must be `Send + Sync`: keep mutable state behind a
/// `Mutex` or an atomic.
pub struct " <> name <> " {}

#[rustler::resource_impl]
impl rustler::Resource for " <> name <> " {}
"
}

fn function_stub(analysis: Analysis, function: ir.Function) -> String {
  let name = naming.rust_identifier(function.name)
  let parameters =
    function.parameters
    |> list.map(fn(p) {
      naming.rust_identifier(p.name)
      <> ": "
      <> rust_type(analysis, p.type_, None)
    })
    |> string.join(", ")
  let return = case function.return {
    ir.Nil -> ""
    type_ -> " -> " <> rust_type(analysis, type_, None)
  }
  let schedule = case function.schedule {
    ir.Normal -> ""
    ir.DirtyCpu -> "/// Runs on a dirty CPU scheduler.\n"
    ir.DirtyIo -> "/// Runs on a dirty I/O scheduler.\n"
  }
  schedule
  <> "fn "
  <> name
  <> "("
  <> parameters
  <> ")"
  <> return
  <> " {\n    todo!("
  <> rust_string("implement " <> function.name)
  <> ")\n}\n"
}
