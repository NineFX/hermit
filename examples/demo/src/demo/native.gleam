//// NIFs implemented in Rust, in `native/demo_native/src/lib.rs`.
////
//// Each `@external(erlang, "demo_native", ...)` function below is a NIF.
//// Hermit reads this module to generate `src/demo_native.erl`, which loads
//// the compiled library, and `native/demo_native/src/generated.rs`, which
//// translates these types to Rust.

import gleam/dict.{type Dict}
import gleam/option.{type Option}

pub type Point {
  Point(x: Float, y: Float)
}

pub type Color {
  Red
  Green
  Blue
  DarkBlue
}

pub type Shape {
  Circle(center: Point, radius: Float)
  Rectangle(Point, Point)
  Polygon(points: List(Point))
  Empty
}

pub type Tree {
  Leaf(Int)
  Node(left: Tree, right: Tree)
}

pub type HTTPError {
  NotFound
  Timeout(after_ms: Int)
}

pub type Mixed {
  Mixed(Int, name: String)
}

/// A counter that lives in Rust. A type without constructors becomes a Rust
/// resource, which Gleam code holds as an opaque reference.
pub type Counter

pub type Pair =
  #(Int, String)

@external(erlang, "demo_native", "add")
pub fn add(a: Int, b: Int) -> Int

@external(erlang, "demo_native", "distance")
pub fn distance(a: Point, b: Point) -> Float

@external(erlang, "demo_native", "area")
pub fn area(shape: Shape) -> Float

@external(erlang, "demo_native", "sum_tree")
pub fn sum_tree(tree: Tree) -> Int

@external(erlang, "demo_native", "mirror")
pub fn mirror(tree: Tree) -> Tree

@external(erlang, "demo_native", "parse_int")
pub fn parse_int(text: String) -> Result(Int, String)

@external(erlang, "demo_native", "first")
pub fn first(items: List(String)) -> Option(String)

@external(erlang, "demo_native", "word_counts")
pub fn word_counts(text: String) -> Dict(String, Int)

@external(erlang, "demo_native", "reverse_bytes")
pub fn reverse_bytes(data: BitArray) -> BitArray

@external(erlang, "demo_native", "next_color")
pub fn next_color(color: Color) -> Color

@external(erlang, "demo_native", "swap")
pub fn swap(pair: Pair) -> #(String, Int)

@external(erlang, "demo_native", "check")
pub fn check(code: Int) -> Result(Nil, HTTPError)

@external(erlang, "demo_native", "new_counter")
pub fn new_counter(start: Int) -> Counter

@external(erlang, "demo_native", "increment")
pub fn increment(counter: Counter) -> Int

/// A growable array of strings that lives in Rust and changes in place, which
/// BEAM data cannot do. Copying a `Vector` copies only the reference, so every
/// copy, in any process, sees the same items.
pub type Vector

@external(erlang, "demo_native", "vector_new")
pub fn vector_new() -> Vector

@external(erlang, "demo_native", "vector_push")
pub fn vector_push(vector: Vector, item: String) -> Nil

@external(erlang, "demo_native", "vector_pop")
pub fn vector_pop(vector: Vector) -> Result(String, Nil)

@external(erlang, "demo_native", "vector_get")
pub fn vector_get(vector: Vector, index: Int) -> Result(String, Nil)

@external(erlang, "demo_native", "vector_set")
pub fn vector_set(vector: Vector, index: Int, item: String) -> Result(Nil, Nil)

@external(erlang, "demo_native", "vector_size")
pub fn vector_size(vector: Vector) -> Int

@external(erlang, "demo_native", "vector_to_list")
pub fn vector_to_list(vector: Vector) -> List(String)

/// Runs on a dirty CPU scheduler, as `gleam.toml` asks, because it can take
/// longer than a NIF on a normal scheduler should.
@external(erlang, "demo_native", "fib")
pub fn fib(n: Int) -> Int

@external(erlang, "demo_native", "upcase")
pub fn upcase_codepoint(c: UtfCodepoint) -> UtfCodepoint

@external(erlang, "demo_native", "describe")
pub fn describe(m: Mixed) -> String

@external(erlang, "demo_native", "log")
pub fn log(message: String) -> Nil
