//! Reverse-interop fixture dump (Wave 6 T6.2): prove the Flutter→PWA direction.
//!
//! The PWA already proved PWA→Flutter (`tests/interop.rs` decodes wasm-produced
//! fixtures in the crate). This bin produces the mirror image: it reads the
//! committed PWA fixture `flutter_app/core/test/fixtures/random-64k/` — the
//! exact `payload.bin` bytes the PWA fed its wasm encoder plus the wire
//! parameters in `manifest.json` — runs the NATIVE `raptorq` 2.0.1 `Encoder`
//! over them, and writes the K systematic source packets to
//! `native.data.frames` in the fixture convention `[u32 BE len][packet bytes]…`.
//!
//! Each packet is the raw RaptorQ wire packet `[SBN u8][ESI BE24] + symbol`,
//! length == mtu — exactly what the wasm `Decoder.decode(packet)` consumes.
//! `tests/interop-gen/reverse.test.ts` feeds these bytes to the PWA's wasm
//! decoder and asserts a byte-identical reassembly.
//!
//! Run from `flutter_app/rust`: `cargo run --bin dump_packets`.

use std::fs;
use std::path::PathBuf;

use raptorq::Encoder;

/// Extract an integer-valued top-level key from the small, known-shaped
/// manifest JSON (keeps serde_json out of the FFI crate).
fn json_u64(manifest: &str, key: &str) -> u64 {
    let needle = format!("\"{key}\"");
    let pos = manifest
        .find(&needle)
        .unwrap_or_else(|| panic!("manifest is missing key {key:?}"));
    manifest[pos + needle.len()..]
        .split_once(':')
        .unwrap_or_else(|| panic!("malformed value for key {key:?}"))
        .1
        .trim_start()
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse()
        .unwrap_or_else(|_| panic!("non-integer value for key {key:?}"))
}

/// Lowercase hex of a byte slice, for the first-packet dump.
fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

fn main() {
    let fixture_dir =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../core/test/fixtures/random-64k");

    // Given — the PWA's committed wire parameters and the exact encoder input.
    let manifest = fs::read_to_string(fixture_dir.join("manifest.json"))
        .unwrap_or_else(|e| panic!("read manifest.json: {e}"));
    let mtu = json_u64(&manifest, "mtu") as u16;
    let k = json_u64(&manifest, "k") as usize;
    let compressed_size = json_u64(&manifest, "compressedSize") as usize;

    let payload = fs::read(fixture_dir.join("payload.bin"))
        .unwrap_or_else(|e| panic!("read payload.bin: {e}"));
    assert_eq!(
        payload.len(),
        compressed_size,
        "payload.bin length != manifest.compressedSize"
    );

    // When — the native crate encodes the exact bytes the PWA encoded.
    let packets = Encoder::with_defaults(&payload, mtu).get_encoded_packets(0);
    assert_eq!(packets.len(), k, "encoder source packet count != manifest.k");
    for (i, packet) in packets.iter().enumerate() {
        assert_eq!(
            packet.serialize().len(),
            mtu as usize,
            "packet {i} length != mtu"
        );
    }

    // Then — serialize in the fixture convention: [u32 BE len][packet bytes]…
    let mut frames = Vec::with_capacity(packets.len() * (4 + mtu as usize));
    for packet in &packets {
        let bytes = packet.serialize();
        frames.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
        frames.extend_from_slice(&bytes);
    }
    let out_path = fixture_dir.join("native.data.frames");
    fs::write(&out_path, &frames).unwrap_or_else(|e| panic!("write {}: {e}", out_path.display()));

    println!(
        "wrote {} source packets (k == manifest.k) to {}",
        packets.len(),
        out_path.display()
    );
    println!("first packet ({} bytes): {}", mtu, hex(&packets[0].serialize()));
}
