//! Builds the C code the NIF calls.
//!
//! `c/checksum.c` is compiled into the NIF itself, which is usually the better
//! choice. `vendor/greet.c` stands in for a prebuilt shared library from a
//! vendor: this script builds it as a shared library, links the NIF against
//! it, and installs it in `priv/` beside the NIF, where the NIF finds it when
//! it loads. If you delete `priv/`, run `cargo clean` here so this script runs
//! again and reinstalls the library.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn main() {
    cc::Build::new().file("c/checksum.c").compile("checksum");

    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap();
    let library = match os.as_str() {
        "windows" => "greet.dll",
        "macos" => "libgreet.dylib",
        _ => "libgreet.so",
    };
    build_shared_library(&out, &os, library);
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=dylib=greet");

    // Tell the dynamic loader to look for the library in the NIF's own
    // directory. Windows has no rpath.
    match os.as_str() {
        "windows" => {}
        "macos" => println!("cargo:rustc-link-arg=-Wl,-rpath,@loader_path"),
        _ => println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN"),
    }

    let priv_dir = Path::new(&env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../priv");
    fs::create_dir_all(&priv_dir).unwrap();
    fs::copy(out.join(library), priv_dir.join(library)).unwrap();

    println!("cargo:rerun-if-changed=c/checksum.c");
    println!("cargo:rerun-if-changed=vendor/greet.c");
}

/// Compiles `vendor/greet.c` into the shared library `out/library` with the
/// C compiler the `cc` crate finds.
fn build_shared_library(out: &Path, os: &str, library: &str) {
    let compiler = cc::Build::new().get_compiler();
    let mut command = compiler.to_command();
    if compiler.is_like_msvc() {
        // Also writes the import library, greet.lib, that the NIF links with.
        command
            .args(["/LD", "vendor/greet.c"])
            .arg(format!("/Fe{}", out.join(library).display()))
            .arg(format!("/Fo{}\\", out.display()));
    } else if os == "macos" {
        command
            .args(["-dynamiclib", "-install_name", "@rpath/libgreet.dylib"])
            .args(["vendor/greet.c", "-o"])
            .arg(out.join(library));
    } else {
        command
            .args(["-shared", "-fPIC", "-Wl,-soname,libgreet.so"])
            .args(["vendor/greet.c", "-o"])
            .arg(out.join(library));
    }
    let status = command.status().expect("could not run the C compiler");
    assert!(status.success(), "the C compiler could not build {library}");
}
