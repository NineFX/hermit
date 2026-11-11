import gleam/list
import gleam/string
import hermit/rust
import simplifile

/// Dependabot moves the examples to each new Rustler release. When a release
/// starts a new series, this fails until `rust.rustler_version`, which
/// generated code is written for and new crates depend on, moves with them.
pub fn examples_use_the_rustler_series_hermit_targets_test() {
  use path <- list.each([
    "examples/demo/native/demo_native/Cargo.toml",
    "examples/linking/native/linking_native/Cargo.toml",
  ])
  let assert Ok(cargo_toml) = simplifile.read(path)
  assert rust.check_rustler_dependency(cargo_toml) == Ok(Nil)
    as "update rust.rustler_version to the Rustler series the examples use"
}

pub fn readme_names_the_rustler_series_hermit_targets_test() {
  let assert Ok(readme) = simplifile.read("README.md")
  assert string.contains(
    readme,
    "This release targets Rustler " <> rust.rustler_version <> ".",
  )
    as "update the Rustler version under Upgrading Rustler in README.md"
}
