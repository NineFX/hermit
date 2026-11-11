//// Hermit generates Rust NIFs, built on Rustler, for Gleam projects.
////
//// Declare NIFs as Erlang externals in a Gleam module, list the module in
//// `gleam.toml`, and run `gleam run -m hermit generate`. Hermit writes an
//// Erlang module that loads the NIF library, and a Rust crate under
//// `native/` with the Gleam types translated to Rust and a stub for each NIF.
//// `gleam run -m hermit build` compiles the crate into `priv/`.

import argv
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import hermit/cargo
import hermit/config
import hermit/erlang
import hermit/gleam_interface
import hermit/ir
import hermit/rust
import simplifile

const usage =
  "hermit: Rust NIFs for Gleam projects, built on Rustler

Usage:
  gleam run -m hermit generate   Write the Erlang loader and Rust crate for each NIF module
  gleam run -m hermit build      Generate, then compile each Rust crate into priv/
  gleam run -m hermit help       Show this message

List the Gleam modules that declare NIFs in gleam.toml:

"

pub fn main() -> Nil {
  let outcome = case argv.load().arguments {
    ["generate"] -> generate()
    ["build"] -> build()
    [] | ["help"] | ["--help"] | ["-h"] -> {
      io.println(usage <> config.example)
      Ok(Nil)
    }
    [command, ..] ->
      Error(
        "unknown command `" <> command <> "`\n\n" <> usage <> config.example,
      )
  }
  case outcome {
    Ok(Nil) -> Nil
    Error(message) -> {
      io.println_error("error: " <> message)
      halt(1)
    }
  }
}

fn generate() -> Result(Nil, String) {
  use libraries <- result.try(load())
  list.try_each(libraries, generate_library)
}

fn build() -> Result(Nil, String) {
  use libraries <- result.try(load())
  list.try_each(libraries, fn(library) {
    use _ <- result.try(generate_library(library))
    io.println("Compiling " <> crate_dir(library))
    use installed <- result.map(
      cargo.build(
        crate_dir: crate_dir(library),
        priv_dir: "priv",
        library_file: erlang.library_file(library),
      )
      |> result.map_error(cargo.describe_error),
    )
    io.println("  installed " <> installed)
  })
}

// Loading ---------------------------------------------------------------------

fn load() -> Result(List(ir.Library), String) {
  use source <- result.try(
    simplifile.read("gleam.toml")
    |> result.replace_error(
      "could not read gleam.toml. Run hermit from the root of a Gleam project.",
    ),
  )
  use config <- result.try(config.parse(source))
  list.try_map(config.nifs, read_library(config.project, _))
}

fn read_library(
  project: String,
  nif: config.Nif,
) -> Result(ir.Library, String) {
  let path = "src/" <> nif.module <> ".gleam"
  use source <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      "could not read " <> path <> ": " <> simplifile.describe_error(error)
    }),
  )
  let options =
    gleam_interface.Options(
      otp_app: project,
      path:,
      dirty_cpu: nif.dirty_cpu,
      dirty_io: nif.dirty_io,
    )
  use library <- result.try(
    gleam_interface.read(source, options)
    |> result.map_error(fn(diagnostics) {
      diagnostics
      |> list.map(gleam_interface.describe(_, path, source))
      |> string.join("\n")
    }),
  )
  use _ <- result.try(
    rust.check(library)
    |> result.map_error(fn(problems) {
      problems |> list.map(fn(p) { path <> ": " <> p }) |> string.join("\n")
    }),
  )
  case library.erlang_module == string.replace(nif.module, "/", "@") {
    True ->
      Error(
        path
        <> ": the NIFs are external to `"
        <> library.erlang_module
        <> "`, which is the Erlang name of the Gleam module itself. "
        <> "Pick another module name, such as `"
        <> string.replace(nif.module, "/", "_")
        <> "_nif`.",
      )
    False -> Ok(library)
  }
}

// Generating ------------------------------------------------------------------

fn crate_dir(library: ir.Library) -> String {
  "native/" <> rust.crate_name(library)
}

fn generate_library(library: ir.Library) -> Result(Nil, String) {
  io.println("Generating " <> library.source)
  let crate_dir = crate_dir(library)
  use _ <- result.try(write_generated(
    "src/" <> library.erlang_module <> ".erl",
    erlang.loader(library),
  ))
  use _ <- result.try(write_generated(
    crate_dir <> "/src/generated.rs",
    rust.generated_rs(library),
  ))
  let cargo_toml = crate_dir <> "/Cargo.toml"
  use _ <- result.try(scaffold(cargo_toml, rust.cargo_toml(library)))
  check_rustler_version(cargo_toml)
  use _ <- result.try(scaffold(crate_dir <> "/.gitignore", rust.gitignore))
  use created <- result.try(scaffold(
    crate_dir <> "/src/lib.rs",
    rust.lib_rs(library),
  ))
  case created {
    True -> Ok(Nil)
    False -> report_missing_stubs(library, crate_dir <> "/src")
  }
}

/// Writes a file hermit owns, refusing to replace one it did not write.
/// Leaves an unchanged file alone so build tools do not rebuild for nothing.
fn write_generated(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.read(path) {
    Ok(existing) if existing == contents -> {
      io.println("  unchanged " <> path)
      Ok(Nil)
    }
    Ok(existing) ->
      case is_generated(existing) {
        True -> write(path, contents, "  wrote " <> path)
        False ->
          Error(
            "refusing to overwrite "
            <> path
            <> ", which hermit did not generate. Move it out of the way and "
            <> "run hermit again.",
          )
      }
    Error(_) -> write(path, contents, "  wrote " <> path)
  }
}

fn is_generated(contents: String) -> Bool {
  string.starts_with(contents, "%% @generated by hermit")
  || string.starts_with(contents, "// @generated by hermit")
}

/// Writes a file the user owns, unless it exists. Returns whether it wrote.
fn scaffold(path: String, contents: String) -> Result(Bool, String) {
  case simplifile.is_file(path) {
    Ok(True) -> {
      io.println("  kept " <> path)
      Ok(False)
    }
    _ ->
      write(path, contents, "  created " <> path)
      |> result.replace(True)
  }
}

fn write(
  path: String,
  contents: String,
  message: String,
) -> Result(Nil, String) {
  let directory = case string.split(path, "/") |> list.reverse {
    [_, ..rest] -> rest |> list.reverse |> string.join("/")
    [] -> "."
  }
  {
    use _ <- result.try(simplifile.create_directory_all(directory))
    simplifile.write(path, contents)
  }
  |> result.map(fn(_) { io.println(message) })
  |> result.map_error(fn(error) {
    "could not write " <> path <> ": " <> simplifile.describe_error(error)
  })
}

/// Warns when the crate depends on a Rustler release series other than the
/// one generated code is written for, since it would likely fail to build.
/// Hermit never changes `Cargo.toml` once it exists, so this is how users
/// learn to update it after upgrading hermit.
fn check_rustler_version(cargo_toml: String) -> Nil {
  let checked =
    simplifile.read(cargo_toml)
    |> result.unwrap("")
    |> rust.check_rustler_dependency
  case checked {
    Ok(Nil) -> Nil
    Error(requirement) ->
      io.println_error(
        "warning: "
        <> cargo_toml
        <> " depends on rustler "
        <> requirement
        <> ", but this version of hermit generates code for rustler "
        <> rust.rustler_version
        <> ". Change the dependency to `rustler = \""
        <> rust.rustler_version
        <> "\"`.",
      )
  }
}

/// Points out NIFs and resources the Gleam module declares that the crate
/// does not seem to define yet, with stubs to paste in.
fn report_missing_stubs(
  library: ir.Library,
  source_dir: String,
) -> Result(Nil, String) {
  let sources =
    simplifile.get_files(source_dir)
    |> result.unwrap([])
    |> list.filter(fn(path) {
      string.ends_with(path, ".rs") && !string.ends_with(path, "/generated.rs")
    })
    |> list.filter_map(simplifile.read)
  case rust.missing_stubs(library, sources) {
    [] -> Nil
    stubs ->
      io.println(
        "\n  "
        <> source_dir
        <> " does not seem to define everything the Gleam module declares."
        <> " Add these to lib.rs:\n\n"
        <> string.join(stubs, "\n"),
      )
  }
  Ok(Nil)
}

@external(erlang, "hermit_ffi", "halt")
fn halt(status: Int) -> Nil
