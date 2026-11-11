import demo/native.{Circle, Point}
import gleam/float
import gleam/int
import gleam/io

pub fn main() -> Nil {
  io.println("2 + 40 = " <> int.to_string(native.add(2, 40)))
  let area = native.area(Circle(center: Point(0.0, 0.0), radius: 2.0))
  io.println("area of a circle of radius 2 = " <> float.to_string(area))
  io.println("fib(40) = " <> int.to_string(native.fib(40)))
}
