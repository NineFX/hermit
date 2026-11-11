//! Rust implementations of the NIFs declared in `src/linking/native.gleam`.
//!
//! Hermit created this file and never overwrites it, so it is yours to edit.
//! Each NIF is a plain Rust function over plain Rust types. The Rust versions
//! of the Gleam types, and the glue that converts them to and from BEAM terms,
//! are in `generated.rs`, which `gleam run -m hermit generate` rewrites.

#[rustfmt::skip]
mod generated;

#[allow(unused_imports)]
use generated::*;
use std::ffi::{CStr, c_char};

// From c/checksum.c, compiled into the NIF.
unsafe extern "C" {
    fn c_checksum(data: *const u8, len: usize) -> u32;
}

// From the greet shared library, which the NIF loads from priv/.
unsafe extern "C" {
    fn greet_message() -> *const c_char;
}

fn checksum(data: BitArray) -> i64 {
    unsafe { c_checksum(data.as_ptr(), data.len()) }.into()
}

fn greeting() -> String {
    unsafe { CStr::from_ptr(greet_message()) }
        .to_string_lossy()
        .into_owned()
}
