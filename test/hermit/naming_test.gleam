import hermit/naming

pub fn constructor_tag_matches_the_gleam_compiler_test() {
  assert naming.constructor_tag("Point") == "point"
  assert naming.constructor_tag("DarkBlue") == "dark_blue"
  assert naming.constructor_tag("HTTPError") == "h_t_t_p_error"
  assert naming.constructor_tag("ABCdef") == "a_b_cdef"
  assert naming.constructor_tag("Foo2Bar") == "foo2_bar"
  assert naming.constructor_tag("Vec2") == "vec2"
}

pub fn erlang_atom_test() {
  assert naming.erlang_atom("add") == "add"
  assert naming.erlang_atom("my_app@native") == "my_app@native"
  assert naming.erlang_atom("Add") == "'Add'"
  assert naming.erlang_atom("do-thing") == "'do-thing'"
  assert naming.erlang_atom("receive") == "'receive'"
  assert naming.erlang_atom("it's") == "'it\\'s'"
  assert naming.erlang_atom("") == "''"
}

pub fn rust_identifier_test() {
  assert naming.rust_identifier("distance") == "distance"
  assert naming.rust_identifier("match") == "match_"
  assert naming.rust_identifier("self") == "self_"
  assert naming.rust_identifier("gen") == "gen_"
}

pub fn crate_name_test() {
  assert naming.crate_name("my_app_native") == "my_app_native"
  assert naming.crate_name("my_app@native") == "my_app_native"
  assert naming.crate_name("Elixir.Foo") == "Elixir_Foo"
}
