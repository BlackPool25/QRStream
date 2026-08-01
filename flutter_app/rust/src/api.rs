//! FRB API surface for the spike (Wave 1 T1.7 DECISION GATE).
//!
//! This is a trivial placeholder: the REAL RaptorQ API lands in T2.1. The only
//! purpose of this file is to prove that `flutter_rust_bridge_codegen` output
//! can be analyzed and tested under standalone Dart (no Flutter SDK).

/// Trivial spike function: proves the codegen -> standalone-Dart-analyze path.
#[flutter_rust_bridge::frb(sync)]
pub fn spike_sum(a: i32, b: i32) -> i32 {
    a + b
}
