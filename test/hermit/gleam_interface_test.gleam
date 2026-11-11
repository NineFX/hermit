import gleam/list
import gleam/option.{None, Some}
import gleam/string
import hermit/gleam_interface.{Options}
import hermit/ir

fn options() -> gleam_interface.Options {
  Options(
    otp_app: "app",
    path: "src/app/nif.gleam",
    dirty_cpu: [],
    dirty_io: [],
  )
}

fn messages(source: String, options: gleam_interface.Options) -> List(String) {
  let assert Error(diagnostics) = gleam_interface.read(source, options)
  list.map(diagnostics, gleam_interface.describe(_, options.path, source))
}

pub fn reads_functions_and_types_test() {
  let source =
    "
import gleam/dict as d
import gleam/option.{type Option}

pub type Point {
  Point(x: Float, y: Float)
}

pub type Handle

pub type Unused(a) {
  Unused(a)
}

type Points =
  List(Point)

pub fn helper() -> Int {
  1
}

@external(erlang, \"app_nif\", \"make\")
pub fn make(
  points: Points,
  _scale: Float,
  _: Int,
) -> #(Option(Handle), d.Dict(String, Int))

@external(erlang, \"app_nif\", \"Close\")
fn close(handle: Handle) -> Result(Nil, String)
"
  let assert Ok(library) = gleam_interface.read(source, options())
  assert library
    == ir.Library(
      erlang_module: "app_nif",
      otp_app: "app",
      source: "src/app/nif.gleam",
      types: [
        ir.Custom("Point", [
          ir.Variant("Point", "point", [
            ir.Field(Some("x"), ir.Float),
            ir.Field(Some("y"), ir.Float),
          ]),
        ]),
        ir.Resource("Handle"),
      ],
      functions: [
        ir.Function(
          name: "make",
          erlang_name: "make",
          parameters: [
            ir.Parameter("points", ir.List(ir.Named("Point"))),
            ir.Parameter("_scale", ir.Float),
            ir.Parameter("arg2", ir.Int),
          ],
          return: ir.Tuple([
            ir.Option(ir.Named("Handle")),
            ir.Dict(ir.String, ir.Int),
          ]),
          schedule: ir.Normal,
        ),
        ir.Function(
          name: "close",
          erlang_name: "Close",
          parameters: [ir.Parameter("handle", ir.Named("Handle"))],
          return: ir.Result(ir.Nil, ir.String),
          schedule: ir.Normal,
        ),
      ],
    )
}

pub fn reads_nested_and_unlabeled_fields_test() {
  let source =
    "
pub type Tree {
  Leaf(Int)
  Node(left: Tree, right: Tree)
}

pub type HTTPError {
  NotFound
  Bytes(BitArray, UtfCodepoint, Bool)
}

@external(erlang, \"app_nif\", \"f\")
pub fn f(tree: Tree) -> HTTPError
"
  let assert Ok(library) = gleam_interface.read(source, options())
  assert library.types
    == [
      ir.Custom("Tree", [
        ir.Variant("Leaf", "leaf", [ir.Field(None, ir.Int)]),
        ir.Variant("Node", "node", [
          ir.Field(Some("left"), ir.Named("Tree")),
          ir.Field(Some("right"), ir.Named("Tree")),
        ]),
      ]),
      ir.Custom("HTTPError", [
        ir.Variant("NotFound", "not_found", []),
        ir.Variant("Bytes", "bytes", [
          ir.Field(None, ir.BitArray),
          ir.Field(None, ir.UtfCodepoint),
          ir.Field(None, ir.Bool),
        ]),
      ]),
    ]
}

pub fn ignores_externals_to_other_targets_test() {
  let source =
    "
@external(javascript, \"./app.mjs\", \"now\")
pub fn now() -> Int

@external(erlang, \"app_nif\", \"add\")
@external(javascript, \"./app.mjs\", \"add\")
pub fn add(a: Int, b: Int) -> Int
"
  let assert Ok(library) = gleam_interface.read(source, options())
  assert list.map(library.functions, fn(f) { f.name }) == ["add"]
}

pub fn applies_schedules_test() {
  let source =
    "
@external(erlang, \"app_nif\", \"a\")
pub fn a() -> Int

@external(erlang, \"app_nif\", \"b\")
pub fn b() -> Int

@external(erlang, \"app_nif\", \"c\")
pub fn c() -> Int
"
  let options = Options(..options(), dirty_cpu: ["a"], dirty_io: ["b"])
  let assert Ok(library) = gleam_interface.read(source, options)
  assert list.map(library.functions, fn(f) { f.schedule })
    == [ir.DirtyCpu, ir.DirtyIo, ir.Normal]
}

pub fn requires_externals_test() {
  assert messages("pub fn a() -> Int { 1 }", options())
    == [
      "src/app/nif.gleam: found no `@external(erlang, ...)` functions in "
      <> "src/app/nif.gleam, so there are no NIFs to generate",
    ]
}

pub fn requires_one_erlang_module_test() {
  let source =
    "@external(erlang, \"one\", \"a\")
pub fn a() -> Int

@external(erlang, \"two\", \"b\")
pub fn b() -> Int
"
  assert messages(source, options())
    == [
      "src/app/nif.gleam:5:1: `b` is external to Erlang module `two`, but "
      <> "`a` is external to `one`. All NIFs in a module must share one "
      <> "Erlang module.",
    ]
}

pub fn reports_every_unsupported_type_test() {
  let source =
    "import gleam/dynamic.{type Dynamic}

pub type Box(a) {
  Box(a)
}

@external(erlang, \"app_nif\", \"a\")
pub fn a(x: Dynamic, f: fn(Int) -> Int) -> Box(Int)

@external(erlang, \"app_nif\", \"b\")
pub fn b(x: element, y: #()) -> Nil
"
  let found = messages(source, options())
  assert list.length(found) == 5
  let assert [dynamic, function, generic, variable, empty_tuple] = found
  assert string.starts_with(
    dynamic,
    "src/app/nif.gleam:8:13: `gleam/dynamic.Dynamic` cannot cross the NIF boundary.",
  )
  assert function
    == "src/app/nif.gleam:8:25: functions cannot cross the NIF boundary"
  assert generic
    == "src/app/nif.gleam:8:44: `Box` has type parameters, but NIF types must be concrete"
  assert variable
    == "src/app/nif.gleam:11:13: type variable `element`: NIF signatures must use concrete types"
  assert string.starts_with(
    empty_tuple,
    "src/app/nif.gleam:11:25: the empty tuple",
  )
}

pub fn reports_unsupported_types_inside_custom_types_test() {
  let source =
    "pub type Wrapper {
  Wrapper(callback: fn() -> Nil)
}

@external(erlang, \"app_nif\", \"a\")
pub fn a(w: Wrapper) -> Nil
"
  assert messages(source, options())
    == ["src/app/nif.gleam:2:21: functions cannot cross the NIF boundary"]
}

pub fn reports_unknown_schedules_test() {
  let source =
    "@external(erlang, \"app_nif\", \"a\")
pub fn a() -> Int
"
  let options = Options(..options(), dirty_cpu: ["a", "b"], dirty_io: ["a"])
  assert messages(source, options)
    == [
      "src/app/nif.gleam: `dirty_cpu` lists `b`, which is not an external "
        <> "function in this module",
      "src/app/nif.gleam: `a` is listed in both `dirty_cpu` and `dirty_io`",
    ]
}

pub fn reports_duplicate_nifs_test() {
  let source =
    "@external(erlang, \"app_nif\", \"same\")
pub fn a(x: Int) -> Int

@external(erlang, \"app_nif\", \"same\")
pub fn b(x: Int) -> Int
"
  assert messages(source, options())
    == [
      "src/app/nif.gleam:5:1: `b` and `a` are both external to `same/1`",
    ]
}

pub fn reports_parse_errors_test() {
  let assert [message] = messages("pub fn (", options())
  assert string.starts_with(message, "src/app/nif.gleam:1:")
  assert string.contains(message, ": unexpected `")
}
