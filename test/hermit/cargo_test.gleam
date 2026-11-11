import hermit/cargo

pub fn finds_the_cdylib_test() {
  let messages =
    "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"proc-macro\"],\"name\":\"rustler_codegen\"},\"filenames\":[\"/t/release/deps/librustler_codegen.dylib\"]}
not json at all
{\"reason\":\"compiler-message\",\"message\":{}}
{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"cdylib\"],\"name\":\"app_nif\"},\"filenames\":[\"C:/t/release/app_nif.dll.lib\",\"C:/t/release/app_nif.dll\"]}
{\"reason\":\"build-finished\",\"success\":true}
"
  assert cargo.cdylib_path(messages) == Ok("C:/t/release/app_nif.dll")
}

pub fn reports_no_cdylib_test() {
  let messages =
    "{\"reason\":\"compiler-artifact\",\"target\":{\"kind\":[\"lib\"],\"name\":\"app_nif\"},\"filenames\":[\"/t/release/libapp_nif.rlib\"]}"
  assert cargo.cdylib_path(messages) == Error(Nil)
}
