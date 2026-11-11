import gleeunit
import linking/native

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn static_library_test() {
  assert native.checksum(<<>>) == 0
  assert native.checksum(<<1, 2, 3>>) == 1026
}

pub fn shared_library_test() {
  assert native.greeting() == "hello from the greet library"
}
