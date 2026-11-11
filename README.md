# hermit

Hermit generates Rust NIFs for Gleam projects, built on
[Rustler](https://github.com/rusterlium/rustler).

You declare NIFs as ordinary Gleam externals. Hermit reads those
declarations and generates everything between them and plain Rust functions:
the Erlang module that loads the library, Rust versions of your Gleam types,
and the code that converts values between BEAM terms and Rust. You write the
Rust function bodies; Gleam calls them like any other function.

```gleam
pub type Point {
  Point(x: Float, y: Float)
}

@external(erlang, "my_app_native", "distance")
pub fn distance(a: Point, b: Point) -> Float
```

```rust
fn distance(a: Point, b: Point) -> f64 {
    ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt()
}
```

## Quick start

You need Gleam on the Erlang target and a Rust toolchain
([rustup](https://rustup.rs)).

1. Add hermit as a dev dependency. Until it is on Hex, point at a checkout:

   ```toml
   [dev_dependencies]
   hermit = { path = "../hermit" }
   ```

2. Write a Gleam module that declares your NIFs as Erlang externals. Every
   `@external(erlang, ...)` function in it is a NIF, and they must all name
   the same Erlang module. That module must not be the Gleam module's own
   Erlang name (`my_app@native`), since hermit generates it.

   ```gleam
   // src/my_app/native.gleam
   @external(erlang, "my_app_native", "add")
   pub fn add(a: Int, b: Int) -> Int
   ```

3. List the module in `gleam.toml`:

   ```toml
   [[tools.hermit.nif]]
   module = "my_app/native"
   ```

4. Generate the loader and the Rust crate:

   ```sh
   gleam run -m hermit generate
   ```

5. Fill in the stubs in `native/my_app_native/src/lib.rs`:

   ```rust
   fn add(a: i64, b: i64) -> i64 {
       a + b
   }
   ```

6. Compile the crate into `priv/`, then use the NIFs as usual:

   ```sh
   gleam run -m hermit build
   gleam test
   ```

[`examples/demo`](examples/demo) is a complete project that uses every
feature below.

## Commands

| Command                        | What it does                                                         |
| ------------------------------ | -------------------------------------------------------------------- |
| `gleam run -m hermit generate` | Writes the Erlang loader and Rust crate for each NIF module.         |
| `gleam run -m hermit build`    | Runs `generate`, then `cargo build --release`, and copies the library into `priv/`. |
| `gleam run -m hermit help`     | Shows usage.                                                         |

Run `build` after changing the Gleam interface or the Rust code, before
`gleam run` or `gleam test`. Gleam does not run Cargo itself.

## What hermit generates

For a module whose NIFs live in the Erlang module `my_app_native`:

| File                                         | Owner  | Contents                                                              |
| -------------------------------------------- | ------ | --------------------------------------------------------------------- |
| `src/my_app_native.erl`                      | hermit | Loads the library from `priv/` and holds a stub for each NIF.         |
| `native/my_app_native/src/generated.rs`      | hermit | Rust types, term conversions, and the `#[rustler::nif]` entry points. |
| `native/my_app_native/src/lib.rs`            | you    | Your NIF implementations. Created once with a stub for each NIF.      |
| `native/my_app_native/Cargo.toml`            | you    | Created once. Add Rust dependencies here.                             |
| `priv/libmy_app_native.so`                   | hermit | The compiled library, written by `build`.                             |

Hermit rewrites the files it owns on every run and never touches yours. When
you add a NIF or resource to the Gleam module, `generate` prints a stub for
anything your crate does not seem to define yet. It refuses to overwrite a
file in its place that it did not generate.

Commit the generated files so the project builds without hermit's help, and
ignore `priv/*.so` (or `priv/*.dll`) and `native/*/target`.

## Types

Each Gleam type maps to a Rust type that NIF functions take and return by
value:

| Gleam                     | Rust                     | Notes                                                          |
| ------------------------- | ------------------------ | -------------------------------------------------------------- |
| `Int`                     | `i64`                    | Values outside 64 bits raise `badarg`.                         |
| `Float`                   | `f64`                    | Returning NaN or infinity panics.                              |
| `Bool`                    | `bool`                   |                                                                |
| `String`                  | `String`                 | Must be valid UTF-8.                                           |
| `BitArray`                | `BitArray`               | Wraps `Vec<u8>`. Must be byte-aligned. Bytes are copied.       |
| `UtfCodepoint`            | `char`                   |                                                                |
| `Nil`                     | `()`                     |                                                                |
| `List(a)`                 | `Vec<A>`                 |                                                                |
| `#(a, b)`                 | `(A, B)`                 | Any arity except `#()`.                                        |
| `Option(a)`               | `Option<A>`              |                                                                |
| `Result(a, e)`            | `Result<A, E>`           |                                                                |
| `Dict(k, v)`              | `HashMap<K, V>`          | Keys cannot contain `Float`, `Dict`, or resources.             |
| Custom type               | Struct or enum           | See below.                                                     |
| Type without constructors | `ResourceArc<T>`         | See below.                                                     |

Type aliases are expanded. `Option` and `Dict` may be imported qualified or
unqualified, under any alias.

### Custom types

Custom types defined in the interface module become Rust types with the same
name. A type with one constructor becomes a struct; a type with several
becomes an enum.

```gleam
pub type Shape {
  Circle(center: Point, radius: Float)
  Rectangle(Point, Point)
  Empty
}
```

```rust
#[derive(Debug, Clone, PartialEq)]
pub enum Shape {
    Circle { center: Point, radius: f64 },
    Rectangle(Point, Point),
    Empty,
}
```

Labeled fields become named fields and unlabeled ones become tuple fields.
A constructor that mixes them gets named fields, with the unlabeled ones
called `field0`, `field1`, and so on. Field names that are Rust keywords get
a trailing underscore (`type` becomes `type_`), as do NIF function names
(`match` is implemented by `fn match_`).

Recursive types work: hermit adds a `Box` wherever Rust needs one to give the
type a size, as in `Node { left: Box<Tree>, right: Box<Tree> }`. Fields inside
a `List` or `Dict` need no box.

Types derive `Debug`, `Clone`, and `PartialEq`, plus `Eq` and `Hash` when no
field holds a `Float` or `Dict`, and `Copy` when no constructor has fields.
Types that hold a resource derive only `Clone`.

Custom types must be concrete: types with type parameters cannot cross the
NIF boundary, and neither can functions or types from modules other than
`gleam/option` and `gleam/dict`. Names that the generated Rust code relies on,
such as `Option`, `Result`, `String`, and `Vec`, cannot be used as type names.

### Resources

A Gleam type without constructors is a resource: a reference to a Rust value
that stays in Rust. Resources let Gleam code hold things BEAM data cannot be,
such as a data structure that changes in place:

```gleam
/// A growable array of strings that lives in Rust.
pub type Vector

@external(erlang, "my_app_native", "vector_new")
pub fn vector_new() -> Vector

@external(erlang, "my_app_native", "vector_push")
pub fn vector_push(vector: Vector, item: String) -> Nil

@external(erlang, "my_app_native", "vector_get")
pub fn vector_get(vector: Vector, index: Int) -> Result(String, Nil)
```

Rust receives and returns a resource as a `ResourceArc<T>`, a
reference-counted pointer like `Arc<T>`, never as a borrowed `&T`. Hermit
scaffolds the struct in `lib.rs`, and you fill it in:

```rust
pub struct Vector {
    items: Mutex<Vec<String>>,
}

#[rustler::resource_impl]
impl rustler::Resource for Vector {}

fn vector_new() -> ResourceArc<Vector> {
    ResourceArc::new(Vector {
        items: Mutex::new(Vec::new()),
    })
}

fn vector_push(vector: ResourceArc<Vector>, item: String) {
    vector.items.lock().unwrap().push(item);
}

fn vector_get(vector: ResourceArc<Vector>, index: i64) -> Result<String, ()> {
    let items = vector.items.lock().unwrap();
    let index = usize::try_from(index).map_err(|_| ())?;
    items.get(index).cloned().ok_or(())
}
```

Gleam code passes a resource around like any other value: it can keep one in
a list or record, hand it to a function, or send it to another process. Every
copy refers to the same Rust value and sees every change, and the items are
copied out only when a NIF returns them. Two resources are equal only when
they refer to the same value, so `vector_new() == vector_new()` is `False`.

A few things to keep in mind:

- NIFs run on several schedulers at once, and any process can hold a
  resource, so Rustler requires resource types to be `Send + Sync`. Keep
  mutable state behind a `Mutex` or an atomic, and hold locks briefly: a NIF
  waiting for a lock blocks its scheduler.
- `std::sync::Mutex` is not reentrant, and locking one twice on the same
  thread never returns. A NIF that takes two resources of the same type can be
  given the same one twice, as in `vector_append(v, v)`, so lock them one at a
  time: copy what you need out of the first and release it before locking the
  second.
- A function that reads a resource is not pure. `vector_get(vector, 0)` can
  return a different result each time, because other code, in this process
  or another, may have changed the vector in between.
- The BEAM drops the Rust value when the last reference to it is garbage
  collected. To run code at that point, implement `Drop`, or the `destructor`
  callback of `rustler::Resource`.

[`examples/demo`](examples/demo) has the full `Vector`, with tests that change
it through a function, a dict, and another process, and a `Counter` built on
an atomic.

### Errors

A NIF reports expected failures by returning a `Result`, which Gleam receives
as `Ok` or `Error`. If an argument does not decode, as with an `Int` too large
for `i64`, the NIF raises `badarg`. If the Rust code panics, Rustler catches
the panic and the NIF raises `nif_panicked` instead of bringing down the VM.

If the library itself cannot load, for example because a shared library it
links against is missing, the loader prints the reason to standard error. The
module then has no NIFs, so calling one raises `undef`, which Gleam reports as
"A function was called but it did not exist."

## Dirty schedulers

A NIF should return within about a millisecond, or it holds up the scheduler
it runs on. Run longer NIFs on dirty schedulers by naming them in
`gleam.toml`:

```toml
[[tools.hermit.nif]]
module = "my_app/native"
dirty_cpu = ["render"]       # CPU-bound work
dirty_io = ["read_archive"]  # blocking I/O
```

## Linking native libraries

Hermit creates `Cargo.toml` once and builds the crate with an ordinary
`cargo build`, so NIFs can call C, or any library with a C interface, the
usual Rust way: through a `-sys` crate, a `#[link]` attribute, or a build
script.

Prefer static linking. It puts the library inside the NIF in `priv/`, so
there is nothing to install or find when the NIF loads. Many `-sys` crates
can build their library from source and link it statically through a feature,
often called `bundled`, `vendored`, or `static`. To compile C files of your
own, add the [`cc`](https://docs.rs/cc) crate under `[build-dependencies]` in
`Cargo.toml`, and a build script beside it:

```rust
// native/my_app_native/build.rs
fn main() {
    cc::Build::new().file("c/checksum.c").compile("checksum");
}
```

```rust
// native/my_app_native/src/lib.rs
unsafe extern "C" {
    fn c_checksum(data: *const u8, len: usize) -> u32;
}

fn checksum(data: BitArray) -> i64 {
    unsafe { c_checksum(data.as_ptr(), data.len()) }.into()
}
```

A shared library is looked up when the NIF loads, so every machine that runs
the app needs it. Link one the system provides by name:

```rust
#[link(name = "z")]
unsafe extern "C" {
    fn zlibVersion() -> *const std::ffi::c_char;
}
```

To ship a shared library with the app instead, put it in `priv/` beside the
NIF. On Linux and macOS, also give the NIF an rpath that points to its own
directory; Windows already searches the NIF's directory for the DLLs it
needs. This build script links against `foo` in the crate's `vendor/`
directory and sets the rpath:

```rust
fn main() {
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    println!("cargo:rustc-link-search=native={dir}/vendor");
    println!("cargo:rustc-link-lib=dylib=foo");
    match std::env::var("CARGO_CFG_TARGET_OS").unwrap().as_str() {
        "windows" => {}
        "macos" => println!("cargo:rustc-link-arg=-Wl,-rpath,@loader_path"),
        _ => println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN"),
    }
}
```

`vendor/` holds `libfoo.so` on Linux, `libfoo.dylib` on macOS, and on
Windows both `foo.dll` and the import library `foo.lib` that the NIF links
with. Hermit installs only the NIF, so copying the library into `priv/` is up
to you. If you commit it there, ignore the NIF by name rather than
`priv/*.so`. On macOS, the rpath applies only if the library's install name
starts with `@rpath/`: `otool -D` shows the name, and
`install_name_tool -id @rpath/libfoo.dylib` changes it.

[`examples/linking`](examples/linking) does all of this, and CI runs it on
Linux, macOS, and Windows. Its `build.rs` compiles a C file into the NIF,
builds a second C file as a shared library to stand in for a vendor's, and
installs that library in `priv/`.

Native code runs inside the VM, with fewer protections than Rust:

- A crash in C code, such as a segmentation fault, brings down the whole VM.
  Rustler turns Rust panics into `nif_panicked`, but it cannot catch these.
- NIFs run on many scheduler threads at once, and one call may run on a
  different thread than the last. Guard a library that is not thread-safe
  with a `Mutex`, and give one that must stay on a single thread a Rust
  thread of its own.
- To hand a C object to Gleam, wrap its pointer in a resource that frees it
  in `Drop`. Resources must be `Send` and `Sync`, which raw pointers are not,
  so you have to promise both with `unsafe impl`. Make that promise only if
  the library allows it. If the object may move between threads but only one
  may use it at a time, implement just `Send` for the pointer's wrapper and
  keep the wrapper in a `Mutex`.
- Calls that block, or take longer than about a millisecond, belong on a
  dirty scheduler.

## How it works

Hermit is a small compiler with a front end and back ends that meet in a
language-neutral description of the NIF library, `hermit/ir`:

```
Gleam module ──glance──▶ hermit/gleam_interface ──▶ hermit/ir.Library
                                                        │
                       ┌────────────────────────────────┤
                       ▼                                ▼
                 hermit/rust                      hermit/erlang
         Cargo.toml, lib.rs, generated.rs     src/<module>.erl loader
```

- `hermit/gleam_interface` parses the Gleam module with
  [glance](https://hexdocs.pm/glance), resolves imports and aliases, and
  reports problems with file, line, and column.
- `hermit/ir` describes the functions and types as the BEAM sees them: an
  `Option` is `{some, X}` or `none`, a constructor is an atom or a tagged
  tuple, and so on.
- `hermit/rust` generates the crate. Conversions go through two traits in
  `generated.rs`, `FromGleam` and `IntoGleam`, implemented for each Rust type
  with the term layout Gleam uses, so they compose to any depth.
- `hermit/erlang` generates the loader. Gleam cannot declare an `-on_load`
  hook, so each library needs this small Erlang module.
- `hermit/cargo` runs Cargo and installs the library in `priv/`.

A generator for Erlang projects would add a second front end, reading the
interface from Erlang (for example `-spec` attributes) and its settings from
`rebar.config`, and reuse the IR and both back ends.

## Development

```sh
gleam test                 # Unit tests
gleam format --check src test

cd examples/demo           # Or examples/linking
gleam run -m hermit build  # Regenerate and compile the example's NIFs
gleam test                 # Call every NIF from Gleam
```

CI runs all of this on Linux, macOS, and Windows.
