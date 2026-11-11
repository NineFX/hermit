import demo/native.{
  Blue, Circle, DarkBlue, Empty, Green, Leaf, Mixed, Node, NotFound, Point,
  Polygon, Rectangle, Red, Timeout,
}
import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn scalars_test() {
  assert native.add(2, 40) == 42
  assert native.add(-9_223_372_036_854_775_807, -1)
    == -9_223_372_036_854_775_808
  assert native.distance(Point(0.0, 0.0), Point(3.0, 4.0)) == 5.0
  assert native.log("hello from gleam") == Nil
}

pub fn custom_types_test() {
  assert float.loosely_equals(
    native.area(Circle(Point(0.0, 0.0), 1.0)),
    3.14159,
    0.0001,
  )
  assert native.area(Rectangle(Point(0.0, 0.0), Point(2.0, 3.0))) == 6.0
  assert native.area(
      Polygon([Point(0.0, 0.0), Point(4.0, 0.0), Point(0.0, 3.0)]),
    )
    == 6.0
  assert native.area(Empty) == 0.0
  assert native.next_color(Red) == Green
  assert native.next_color(Blue) == DarkBlue
  assert native.next_color(DarkBlue) == Red
  assert native.describe(Mixed(7, name: "seven")) == "seven is 7"
}

pub fn recursive_types_test() {
  let tree = Node(Leaf(1), Node(Leaf(2), Leaf(3)))
  assert native.sum_tree(tree) == 6
  assert native.mirror(tree) == Node(Node(Leaf(3), Leaf(2)), Leaf(1))
}

pub fn result_and_option_test() {
  assert native.parse_int(" 12 ") == Ok(12)
  let assert Error(message) = native.parse_int("twelve")
  assert string.contains(message, "invalid digit")
  assert native.first(["a", "b"]) == Some("a")
  assert native.first([]) == None
  assert native.check(200) == Ok(Nil)
  assert native.check(404) == Error(NotFound)
  assert native.check(503) == Error(Timeout(after_ms: 503))
}

pub fn collections_test() {
  assert native.word_counts("a b a c a")
    == dict.from_list([#("a", 3), #("b", 1), #("c", 1)])
  assert native.swap(#(1, "one")) == #("one", 1)
  assert native.reverse_bytes(<<1, 2, 3>>) == <<3, 2, 1>>
  assert native.reverse_bytes(<<>>) == <<>>
  let assert Ok(e) = string.utf_codepoint(0xE9)
  let assert Ok(upper) = string.utf_codepoint(0xC9)
  assert native.upcase_codepoint(e) == upper
}

pub fn resource_test() {
  let counter = native.new_counter(10)
  assert native.increment(counter) == 11
  assert native.increment(counter) == 12
}

pub fn mutable_resource_test() {
  let vector = native.vector_new()
  assert native.vector_size(vector) == 0
  assert native.vector_pop(vector) == Error(Nil)
  native.vector_push(vector, "a")
  native.vector_push(vector, "b")
  native.vector_push(vector, "c")
  assert native.vector_size(vector) == 3
  assert native.vector_get(vector, 1) == Ok("b")
  assert native.vector_get(vector, 3) == Error(Nil)
  assert native.vector_get(vector, -1) == Error(Nil)
  assert native.vector_set(vector, 1, "B") == Ok(Nil)
  assert native.vector_set(vector, 3, "d") == Error(Nil)
  assert native.vector_set(vector, -1, "z") == Error(Nil)
  assert native.vector_pop(vector) == Ok("c")
  assert native.vector_to_list(vector) == ["a", "B"]
}

fn push_all(vector: native.Vector, items: List(String)) -> Nil {
  list.each(items, native.vector_push(vector, _))
}

pub fn shared_resource_test() {
  let vector = native.vector_new()

  // Every copy of a resource refers to the same Rust value, whether it is
  // passed to a function, stored in a dict, or sent to another process.
  push_all(vector, ["from a function"])
  let assert Ok(copy) =
    dict.from_list([#("shared", vector)]) |> dict.get("shared")
  native.vector_push(copy, "through a dict")
  let done = process.new_subject()
  process.spawn(fn() {
    native.vector_push(vector, "from another process")
    process.send(done, vector)
  })
  let assert Ok(returned) = process.receive(done, 1000)
  assert native.vector_to_list(vector)
    == ["from a function", "through a dict", "from another process"]

  // Resources compare by identity, not by contents.
  assert returned == vector
  assert native.vector_new() != native.vector_new()
}

pub fn dirty_scheduler_test() {
  assert native.fib(30) == 832_040
}
