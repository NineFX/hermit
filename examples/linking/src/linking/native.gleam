//// NIFs that call C code, implemented in `native/linking_native/src/lib.rs`.
////
//// The crate's `build.rs` compiles the C code: `c/checksum.c` into the NIF
//// itself, and `vendor/greet.c` into a separate shared library that ships in
//// `priv/` beside the NIF.

/// Calls C code compiled into the NIF.
@external(erlang, "linking_native", "checksum")
pub fn checksum(data: BitArray) -> Int

/// Calls a function in a shared library that the NIF loads from `priv/`.
@external(erlang, "linking_native", "greeting")
pub fn greeting() -> String
