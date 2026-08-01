//! RaptorQ FFI core for the Flutter app.
//!
//! Wave 0 T0.3: skeleton only. The real FFI API surface is added in T2.1.
//!
//! The `flutter_rust_bridge` generated glue module (`frb_generated.rs`) does not
//! exist yet — it is produced by `flutter_rust_bridge_codegen` in T1.7. Until
//! then, the codegen reference below stays commented out so the crate compiles
//! standalone. T2.1 populates it:
//!
//! ```ignore
//! flutter_rust_bridge::frb_generated(); // requires the generated file
//! ```

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
