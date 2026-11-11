//// A language-neutral description of a NIF library.
////
//// Front ends (today Gleam, later Erlang) parse an interface into a
//// `Library`, and back ends turn that `Library` into a Rustler crate and an
//// Erlang module that loads it. Types here describe how values look on the
//// BEAM, which is what the Rust side has to encode and decode.

import gleam/list
import gleam/option.{type Option}

/// A set of NIFs that share one Erlang module and one Rust crate.
pub type Library {
  Library(
    /// The Erlang module the NIFs are loaded into, such as `my_app_native`.
    erlang_module: String,
    /// The OTP application whose `priv` directory holds the compiled library.
    otp_app: String,
    /// The file the interface was read from, quoted in generated headers.
    source: String,
    /// Every type a NIF signature refers to, directly or through other types.
    types: List(TypeDef),
    functions: List(Function),
  )
}

pub type Function {
  Function(
    /// The function's name in the source language. The Rust function that
    /// implements the NIF takes this name.
    name: String,
    /// The Erlang function the NIF is registered as.
    erlang_name: String,
    parameters: List(Parameter),
    return: Type,
    schedule: Schedule,
  )
}

pub type Parameter {
  Parameter(name: String, type_: Type)
}

/// Which BEAM scheduler runs the NIF. NIFs that run for more than a
/// millisecond or so belong on a dirty scheduler.
pub type Schedule {
  Normal
  DirtyCpu
  DirtyIo
}

/// The shape of a value crossing the NIF boundary.
pub type Type {
  /// An integer that fits in 64 bits.
  Int
  /// A 64-bit float.
  Float
  /// The atoms `true` and `false`.
  Bool
  /// A UTF-8 binary.
  String
  /// A byte-aligned binary.
  BitArray
  /// An integer that is a Unicode scalar value.
  UtfCodepoint
  /// The atom `nil`.
  Nil
  /// A proper list.
  List(element: Type)
  /// A tuple of fixed arity.
  Tuple(elements: List(Type))
  /// `{some, Value}` or the atom `none`.
  Option(value: Type)
  /// `{ok, Value}` or `{error, Reason}`.
  Result(ok: Type, error: Type)
  /// A map.
  Dict(key: Type, value: Type)
  /// A type defined by the library, found in `Library.types`.
  Named(name: String)
}

pub type TypeDef {
  /// A type with constructors. A constructor without fields is an atom, and
  /// one with fields is a tuple tagged with an atom.
  Custom(name: String, variants: List(Variant))
  /// A type without constructors, backed by a Rust resource that the BEAM
  /// sees as an opaque reference.
  Resource(name: String)
}

pub type Variant {
  Variant(
    name: String,
    /// The atom that tags the constructor on the BEAM.
    tag: String,
    fields: List(Field),
  )
}

pub type Field {
  Field(label: Option(String), type_: Type)
}

pub fn type_def_name(definition: TypeDef) -> String {
  case definition {
    Custom(name:, ..) | Resource(name:) -> name
  }
}

/// The names of the library types a type refers to.
pub fn referenced_types(type_: Type) -> List(String) {
  case type_ {
    Named(name) -> [name]
    List(t) | Option(t) -> referenced_types(t)
    Result(a, b) | Dict(a, b) ->
      list.append(referenced_types(a), referenced_types(b))
    Tuple(elements) -> list.flat_map(elements, referenced_types)
    Int | Float | Bool | String | BitArray | UtfCodepoint | Nil -> []
  }
}
