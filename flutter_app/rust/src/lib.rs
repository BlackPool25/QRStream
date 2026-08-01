//! RaptorQ FFI core for the Flutter app.
//!
//! Wave 1 T1.7: FRB spike. `mod api;` carries the placeholder API (the real
//! RaptorQ surface lands in T2.1). The `bridge_generated.rs` module is produced
//! by `flutter_rust_bridge_codegen` and injected into this file automatically.

mod api;
pub use api::*;
mod bridge_generated;

pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[cfg(test)]
mod tests {
    #[test]
    fn add_works() {
        assert_eq!(super::add(2, 3), 5);
    }
}
