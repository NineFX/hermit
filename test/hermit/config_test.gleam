import gleam/string
import hermit/config.{Config, Nif}

pub fn parses_nifs_test() {
  let source =
    "name = \"my_app\"
version = \"1.0.0\"

[[tools.hermit.nif]]
module = \"my_app/native\"
dirty_cpu = [\"fib\"]
dirty_io = [\"slurp\", \"spew\"]

[[tools.hermit.nif]]
module = \"my_app/other\"
"
  assert config.parse(source)
    == Ok(
      Config(project: "my_app", nifs: [
        Nif(module: "my_app/native", dirty_cpu: ["fib"], dirty_io: [
          "slurp", "spew",
        ]),
        Nif(module: "my_app/other", dirty_cpu: [], dirty_io: []),
      ]),
    )
}

pub fn requires_nifs_test() {
  let assert Error(message) = config.parse("name = \"my_app\"\n")
  assert string.starts_with(message, "gleam.toml declares no NIF modules.")
  assert string.ends_with(message, config.example)
}

pub fn rejects_bad_entries_test() {
  assert config.parse("name = \"a\"\n[[tools.hermit.nif]]\ndirty_cpu = []\n")
    == Error("each `tools.hermit.nif` entry needs a `module`")
  assert config.parse(
      "name = \"a\"\n[[tools.hermit.nif]]\nmodule = \"a/b\"\ndirty_io = \"x\"\n",
    )
    == Error("`dirty_io` for a/b must be an array of function names")
  assert config.parse("name = \"a\"\n[tools.hermit]\nnif = 1\n")
    == Error("`tools.hermit.nif` in gleam.toml must be an array of tables")
  assert config.parse("[[tools.hermit.nif]]\nmodule = \"a/b\"\n")
    == Error("gleam.toml has no `name`")
}
