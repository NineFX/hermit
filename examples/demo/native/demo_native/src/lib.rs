//! Rust implementations of the NIFs declared in `src/demo/native.gleam`.
//!
//! Hermit created this file and never overwrites it, so it is yours to edit.
//! Each NIF is a plain Rust function over plain Rust types. The Rust versions
//! of the Gleam types, and the glue that converts them to and from BEAM terms,
//! are in `generated.rs`, which `gleam run -m hermit generate` rewrites.

#[rustfmt::skip]
mod generated;

use generated::*;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Mutex, MutexGuard};

pub struct Counter {
    value: AtomicI64,
}

#[rustler::resource_impl]
impl rustler::Resource for Counter {}

/// Backs the Gleam type `Vector`. NIFs can run on several schedulers at once,
/// so the items sit behind a `Mutex`.
pub struct Vector {
    items: Mutex<Vec<String>>,
}

#[rustler::resource_impl]
impl rustler::Resource for Vector {}

impl Vector {
    /// Locks the items. The lock is held until the guard is dropped, so keep
    /// it short: a NIF waiting for it blocks its scheduler.
    fn items(&self) -> MutexGuard<'_, Vec<String>> {
        self.items.lock().unwrap()
    }
}

fn add(a: i64, b: i64) -> i64 {
    a + b
}

fn distance(a: Point, b: Point) -> f64 {
    ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt()
}

fn area(shape: Shape) -> f64 {
    match shape {
        Shape::Circle { radius, .. } => std::f64::consts::PI * radius * radius,
        Shape::Rectangle(a, b) => ((b.x - a.x) * (b.y - a.y)).abs(),
        Shape::Polygon { points } => {
            let n = points.len();
            let twice: f64 = (0..n)
                .map(|i| {
                    let (p, q) = (&points[i], &points[(i + 1) % n]);
                    p.x * q.y - q.x * p.y
                })
                .sum();
            twice.abs() / 2.0
        }
        Shape::Empty => 0.0,
    }
}

fn sum_tree(tree: Tree) -> i64 {
    match tree {
        Tree::Leaf(n) => n,
        Tree::Node { left, right } => sum_tree(*left) + sum_tree(*right),
    }
}

fn mirror(tree: Tree) -> Tree {
    match tree {
        Tree::Leaf(n) => Tree::Leaf(n),
        Tree::Node { left, right } => Tree::Node {
            left: Box::new(mirror(*right)),
            right: Box::new(mirror(*left)),
        },
    }
}

fn parse_int(text: String) -> Result<i64, String> {
    text.trim().parse().map_err(|e| format!("{e}"))
}

fn first(items: Vec<String>) -> Option<String> {
    items.into_iter().next()
}

fn word_counts(text: String) -> HashMap<String, i64> {
    let mut counts = HashMap::new();
    for word in text.split_whitespace() {
        *counts.entry(word.to_string()).or_insert(0) += 1;
    }
    counts
}

fn reverse_bytes(data: BitArray) -> BitArray {
    data.iter().rev().copied().collect::<Vec<u8>>().into()
}

fn next_color(color: Color) -> Color {
    match color {
        Color::Red => Color::Green,
        Color::Green => Color::Blue,
        Color::Blue => Color::DarkBlue,
        Color::DarkBlue => Color::Red,
    }
}

fn swap(pair: (i64, String)) -> (String, i64) {
    (pair.1, pair.0)
}

fn check(code: i64) -> Result<(), HTTPError> {
    match code {
        200 => Ok(()),
        404 => Err(HTTPError::NotFound),
        _ => Err(HTTPError::Timeout { after_ms: code }),
    }
}

fn new_counter(start: i64) -> ResourceArc<Counter> {
    ResourceArc::new(Counter {
        value: AtomicI64::new(start),
    })
}

fn increment(counter: ResourceArc<Counter>) -> i64 {
    counter.value.fetch_add(1, Ordering::SeqCst) + 1
}

fn vector_new() -> ResourceArc<Vector> {
    ResourceArc::new(Vector {
        items: Mutex::new(Vec::new()),
    })
}

fn vector_push(vector: ResourceArc<Vector>, item: String) {
    vector.items().push(item);
}

fn vector_pop(vector: ResourceArc<Vector>) -> Result<String, ()> {
    vector.items().pop().ok_or(())
}

fn vector_get(vector: ResourceArc<Vector>, index: i64) -> Result<String, ()> {
    let items = vector.items();
    let index = usize::try_from(index).map_err(|_| ())?;
    items.get(index).cloned().ok_or(())
}

fn vector_set(vector: ResourceArc<Vector>, index: i64, item: String) -> Result<(), ()> {
    let mut items = vector.items();
    let index = usize::try_from(index).map_err(|_| ())?;
    let slot = items.get_mut(index).ok_or(())?;
    *slot = item;
    Ok(())
}

fn vector_size(vector: ResourceArc<Vector>) -> i64 {
    vector.items().len() as i64
}

fn vector_to_list(vector: ResourceArc<Vector>) -> Vec<String> {
    vector.items().clone()
}

fn fib(n: i64) -> i64 {
    if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}

fn upcase_codepoint(c: char) -> char {
    c.to_uppercase().next().unwrap_or(c)
}

fn describe(m: Mixed) -> String {
    format!("{} is {}", m.name, m.field0)
}

fn log(message: String) {
    eprintln!("[demo_native] {message}");
}
