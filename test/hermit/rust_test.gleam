import gleam/option.{None, Some}
import gleam/string
import hermit/ir
import hermit/rust

fn library(
  types: List(ir.TypeDef),
  functions: List(ir.Function),
) -> ir.Library {
  ir.Library(
    erlang_module: "app_nif",
    otp_app: "app",
    source: "src/app/nif.gleam",
    types:,
    functions:,
  )
}

fn function(
  name: String,
  parameters: List(ir.Type),
  return: ir.Type,
) -> ir.Function {
  ir.Function(
    name:,
    erlang_name: name,
    parameters: case parameters {
      [] -> []
      [a] -> [ir.Parameter("a", a)]
      [a, b, ..] -> [ir.Parameter("a", a), ir.Parameter("b", b)]
    },
    return:,
    schedule: ir.Normal,
  )
}

const tree =
  ir.Custom(
    "Tree",
    [
      ir.Variant("Leaf", "leaf", [ir.Field(None, ir.Int)]),
      ir.Variant(
        "Node",
        "node",
        [
          ir.Field(Some("left"), ir.Named("Tree")),
          ir.Field(Some("right"), ir.Option(ir.Named("Tree"))),
          ir.Field(Some("children"), ir.List(ir.Named("Tree"))),
        ],
      ),
    ],
  )

pub fn crate_name_test() {
  assert rust.crate_name(ir.Library(..library([], []), erlang_module: "a@b"))
    == "a_b"
}

pub fn check_accepts_hashable_keys_test() {
  let lib =
    library([tree], [
      function("f", [ir.Dict(ir.Named("Tree"), ir.Float)], ir.Nil),
      function("g", [ir.Dict(ir.Tuple([ir.String, ir.Int]), ir.Int)], ir.Nil),
    ])
  assert rust.check(lib) == Ok(Nil)
}

pub fn check_rejects_unhashable_keys_test() {
  let point =
    ir.Custom("Point", [
      ir.Variant("Point", "point", [ir.Field(None, ir.Float)]),
    ])
  let lib =
    library([point, ir.Resource("Handle")], [
      function("f", [ir.Dict(ir.Float, ir.Int)], ir.Nil),
      function("g", [ir.Dict(ir.Named("Point"), ir.Int)], ir.Nil),
      function("h", [], ir.List(ir.Dict(ir.Named("Handle"), ir.Int))),
    ])
  assert rust.check(lib)
    == Error([
      "function `f` uses `Dict` with key type Float, which Rust cannot hash. "
        <> "Dict keys cannot contain Float, Dict, or resource types.",
      "function `g` uses `Dict` with key type Point, which Rust cannot hash. "
        <> "Dict keys cannot contain Float, Dict, or resource types.",
      "function `h` uses `Dict` with key type Handle, which Rust cannot hash. "
        <> "Dict keys cannot contain Float, Dict, or resource types.",
    ])
}

pub fn check_rejects_reserved_names_test() {
  let result_type = ir.Custom("Result", [ir.Variant("Self", "self", [])])
  assert rust.check(library([result_type], [])) |> string.inspect
    == string.inspect(
      Error([
        "type `Result` clashes with a name the generated Rust code uses; rename it",
        "constructor `Self` of `Result` is a Rust keyword; rename it",
      ]),
    )
}

pub fn boxes_recursive_fields_only_test() {
  let generated =
    rust.generated_rs(
      library([tree], [function("f", [ir.Named("Tree")], ir.Nil)]),
    )
  assert string.contains(
    generated,
    "    Node { left: Box<Tree>, right: Option<Box<Tree>>, children: Vec<Tree> },\n",
  )
  assert string.contains(generated, "    Leaf(i64),\n")
}

pub fn derives_what_the_fields_allow_test() {
  let color =
    ir.Custom("Color", [
      ir.Variant("Red", "red", []),
      ir.Variant("Blue", "blue", []),
    ])
  let point =
    ir.Custom("Point", [
      ir.Variant("Point", "point", [ir.Field(Some("x"), ir.Float)]),
    ])
  let holder =
    ir.Custom("Holder", [
      ir.Variant("Holder", "holder", [ir.Field(None, ir.Named("Handle"))]),
    ])
  let generated =
    rust.generated_rs(
      library([color, point, holder, ir.Resource("Handle")], [
        function(
          "f",
          [ir.Named("Color"), ir.Named("Point")],
          ir.Named("Holder"),
        ),
      ]),
    )
  assert string.contains(
    generated,
    "#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]\npub enum Color {\n    Red,\n    Blue,\n}\n",
  )
  assert string.contains(
    generated,
    "#[derive(Debug, Clone, PartialEq)]\npub struct Point {\n    pub x: f64,\n}\n",
  )
  assert string.contains(
    generated,
    "#[derive(Clone)]\npub struct Holder(pub ResourceArc<Handle>);\n",
  )
}

pub fn names_mixed_fields_by_position_test() {
  let mixed =
    ir.Custom("Mixed", [
      ir.Variant("Mixed", "mixed", [
        ir.Field(None, ir.Int),
        ir.Field(Some("type"), ir.String),
      ]),
    ])
  let generated = rust.generated_rs(library([mixed], []))
  assert string.contains(
    generated,
    "pub struct Mixed {\n    pub field0: i64,\n    pub type_: String,\n}\n",
  )
  assert string.contains(
    generated,
    "        let Mixed { field0: f0, type_: f1 } = self;\n"
      <> "        record(env, atoms::mixed(), &[f0.into_gleam(env), f1.into_gleam(env)])\n",
  )
}

pub fn escapes_keyword_atoms_test() {
  let keyword =
    ir.Custom("Kind", [
      ir.Variant("Match", "match", []),
      ir.Variant("Other", "other", []),
    ])
  let generated = rust.generated_rs(library([keyword], []))
  assert string.contains(generated, "        match_ = \"match\",\n")
  assert string.contains(generated, "        other,\n")
  assert string.contains(
    generated,
    "            (tag, fields) if tag == atoms::match_() && fields.is_empty() => Ok(Kind::Match),\n",
  )
}

pub fn generates_tuple_impls_for_used_arities_test() {
  let generated =
    rust.generated_rs(
      library([], [
        function(
          "f",
          [ir.Tuple([ir.Int])],
          ir.List(ir.Tuple([ir.Int, ir.String, ir.Bool])),
        ),
      ]),
    )
  assert string.contains(
    generated,
    "impl<'a, T0: FromGleam<'a>> FromGleam<'a> for (T0,) {",
  )
  assert string.contains(
    generated,
    "impl<'a, T0: FromGleam<'a>, T1: FromGleam<'a>, T2: FromGleam<'a>> FromGleam<'a> for (T0, T1, T2) {",
  )
  assert !string.contains(generated, "for (T0, T1) {")
}

pub fn generates_nif_entry_points_test() {
  let dirty =
    ir.Function(
      name: "match",
      erlang_name: "Match",
      parameters: [ir.Parameter("a", ir.Int)],
      return: ir.Int,
      schedule: ir.DirtyCpu,
    )
  let generated =
    rust.generated_rs(library([], [dirty, function("now", [], ir.Int)]))
  assert string.contains(
    generated,
    "    #[rustler::nif(name = \"Match\", schedule = \"DirtyCpu\")]
    fn match_<'a>(env: Env<'a>, arg0: Term<'a>) -> NifResult<Term<'a>> {
        let result = crate::match_(FromGleam::from_gleam(arg0)?);
        Ok(result.into_gleam(env))
    }
",
  )
  assert string.contains(
    generated,
    "    fn now<'a>(env: Env<'a>) -> NifResult<Term<'a>> {
        let result = crate::now();
",
  )
  assert string.ends_with(generated, "rustler::init!(\"app_nif\");\n")
}

pub fn scaffolds_lib_rs_test() {
  let lib =
    library([ir.Resource("Handle")], [
      function("open", [ir.String], ir.Result(ir.Named("Handle"), ir.String)),
      function("close", [ir.Named("Handle")], ir.Nil),
      ir.Function(
        ..function(
          "crunch",
          [ir.BitArray],
          ir.Dict(ir.String, ir.List(ir.UtfCodepoint)),
        ),
        schedule: ir.DirtyIo,
      ),
    ])
  let lib_rs = rust.lib_rs(lib)
  assert string.contains(
    lib_rs,
    "#[rustfmt::skip]\nmod generated;\n\n#[allow(unused_imports)]\nuse generated::*;\n",
  )
  assert string.contains(
    lib_rs,
    "pub struct Handle {}\n\n#[rustler::resource_impl]\nimpl rustler::Resource for Handle {}\n",
  )
  assert string.contains(
    lib_rs,
    "fn open(a: String) -> Result<ResourceArc<Handle>, String> {\n    todo!(\"implement open\")\n}\n",
  )
  assert string.contains(lib_rs, "fn close(a: ResourceArc<Handle>) {\n")
  assert string.contains(
    lib_rs,
    "/// Runs on a dirty I/O scheduler.\nfn crunch(a: BitArray) -> HashMap<String, Vec<char>> {\n",
  )
}

pub fn finds_missing_stubs_test() {
  let lib =
    library([ir.Resource("Handle")], [
      function("open", [], ir.Named("Handle")),
      function("close", [ir.Named("Handle")], ir.Nil),
      function("flush", [], ir.Nil),
    ])
  let sources = [
    "pub struct Handle { fd: i32 }\nfn open() -> ResourceArc<Handle> { todo!() }",
    "pub fn close<'a>(handle: ResourceArc<Handle>) {}",
  ]
  assert rust.missing_stubs(lib, sources)
    == ["fn flush() {\n    todo!(\"implement flush\")\n}\n"]
  assert rust.missing_stubs(lib, []) == rust.stubs(lib)
}

pub fn cargo_toml_test() {
  assert string.contains(rust.cargo_toml(library([], [])), "name = \"app_nif\"")
  assert string.contains(
    rust.cargo_toml(library([], [])),
    "crate-type = [\"cdylib\"]",
  )
  assert string.contains(rust.cargo_toml(library([], [])), "rustler = \"0.39\"")
}
