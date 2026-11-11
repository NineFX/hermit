//// Builds a NIF crate with Cargo and installs the library where the Erlang
//// loader looks for it.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub type CommandError {
  CommandNotFound(name: String)
  CommandFailed(status: Int)
}

pub type BuildError {
  CargoNotFound
  CargoFailed(status: Int)
  NoLibrary(crate_dir: String)
  CopyFailed(destination: String, reason: simplifile.FileError)
}

pub fn describe_error(error: BuildError) -> String {
  case error {
    CargoNotFound ->
      "could not find `cargo` on the PATH. Install Rust from https://rustup.rs"
    CargoFailed(status:) ->
      "cargo failed with exit status " <> string.inspect(status)
    NoLibrary(crate_dir:) ->
      "cargo built no cdylib for "
      <> crate_dir
      <> ". Its Cargo.toml needs `crate-type = [\"cdylib\"]` under `[lib]`."
    CopyFailed(destination:, reason:) ->
      "could not write "
      <> destination
      <> ": "
      <> simplifile.describe_error(reason)
  }
}

/// Builds the crate in `crate_dir` in release mode and copies the library to
/// `priv_dir`, named `library_file` plus the extension `erlang:load_nif/2`
/// expects. Returns the path it copied to.
pub fn build(
  crate_dir crate_dir: String,
  priv_dir priv_dir: String,
  library_file library_file: String,
) -> Result(String, BuildError) {
  use output <- result.try(
    run(
      "cargo",
      [
        "build",
        "--release",
        "--message-format=json-render-diagnostics",
        "--manifest-path",
        crate_dir <> "/Cargo.toml",
      ],
      ".",
    )
    |> result.map_error(fn(error) {
      case error {
        CommandNotFound(_) -> CargoNotFound
        CommandFailed(status:) -> CargoFailed(status)
      }
    }),
  )
  use built <- result.try(
    cdylib_path(output) |> result.replace_error(NoLibrary(crate_dir)),
  )
  let extension = case os_family() {
    Windows -> ".dll"
    Unix -> ".so"
  }
  let destination = priv_dir <> "/" <> library_file <> extension
  // Replace the file rather than overwrite it in place. macOS kills processes
  // that load a signed library whose file changed under them.
  let _ = simplifile.delete(destination)
  {
    use _ <- result.try(simplifile.create_directory_all(priv_dir))
    simplifile.copy_file(built, destination)
  }
  |> result.map_error(CopyFailed(destination, _))
  |> result.replace(destination)
}

/// Finds the shared library in the JSON messages of
/// `cargo build --message-format=json`.
pub fn cdylib_path(messages: String) -> Result(String, Nil) {
  let decoder = {
    use reason <- decode.field("reason", decode.string)
    case reason {
      "compiler-artifact" -> {
        use kinds <- decode.subfield(
          ["target", "kind"],
          decode.list(decode.string),
        )
        use filenames <- decode.field("filenames", decode.list(decode.string))
        case list.contains(kinds, "cdylib") {
          True -> decode.success(filenames)
          False -> decode.success([])
        }
      }
      _ -> decode.success([])
    }
  }
  messages
  |> string.split("\n")
  |> list.flat_map(fn(line) { json.parse(line, decoder) |> result.unwrap([]) })
  |> list.find(fn(filename) {
    string.ends_with(filename, ".so")
    || string.ends_with(filename, ".dylib")
    || string.ends_with(filename, ".dll")
  })
}

type OsFamily {
  Windows
  Unix
}

@external(erlang, "hermit_ffi", "os_family")
fn os_family() -> OsFamily

@external(erlang, "hermit_ffi", "run")
fn run(
  executable: String,
  arguments: List(String),
  directory: String,
) -> Result(String, CommandError)
