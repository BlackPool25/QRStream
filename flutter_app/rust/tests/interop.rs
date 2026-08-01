//! PWA ↔ Flutter RaptorQ wire-compatibility proof (Wave 2 T2.2).
//!
//! Feeds the committed fixtures produced by the PWA's REAL pipeline
//! (`core/test/fixtures/*`): each `data.frames` stream carries RaptorQ packets
//! (`[SBN u8][ESI BE24] + symbol bytes`, length == mtu) serialized by the
//! PWA's wasm raptorq v1.7.24. A crate v2.0.1 `Decoder` must reassemble them
//! byte-identical to `payload.bin` — the flagship interop claim.
//!
//! RESULTS (verified 2026-08-01, raptorq =2.0.1):
//! - Source-symbol path: INTEROP HOLDS. All k DATA packets decode byte-
//!   identical (systematic code: source packets carry the raw data, and the
//!   decoder's all-source-symbols fast path returns them directly).
//! - Repair-symbol path: INTEROP BREAKS, pinned by the tests below. raptorq
//!   2.0.1 changed the repair-packet ESI on the wire from `K' + i` (RFC 6330,
//!   used by v1.7.x/wasm) to `kt + i`, and its decoder compensates by adding
//!   `K' - kt` before computing the encoding tuple. A 2.0.1 decoder fed a PWA
//!   repair packet (ESI = `K' + i`) looks up tuple ESI `K' + i + (K' - kt)` and
//!   reconstructs garbage (or never completes). See
//!   `pwa_repair_packets_as_encoded_expose_esi_regression` for the exact field
//!   offset per fixture; the PWA repair DATA is intact — relabeling its ESI by
//!   the crate's convention decodes byte-identical
//!   (`pwa_packets_decode_with_loss_via_relabeled_repair`).
//!
//! The test drives the `raptorq` crate directly (a dependency), not the FRB
//! FFI wrapper, so it is independent of the bridge surface.

use std::fs;
use std::path::{Path, PathBuf};

use raptorq::{Decoder, Encoder, EncodingPacket, ObjectTransmissionInformation, PayloadId};

/// One PWA fixture, parsed and wire-verified.
struct Fixture {
    name: &'static str,
    /// Exact bytes the PWA fed to its encoder (== manifest.compressedSize).
    payload: Vec<u8>,
    /// Source-symbol packets from `data.frames` (ESI 0..k).
    source_packets: Vec<EncodingPacket>,
    /// Repair-symbol packets from `repair.frames` (ESI K'.. on the PWA wire).
    repair_packets: Vec<EncodingPacket>,
    /// Wire packet size == frame `blockLen` == manifest.mtu.
    mtu: u16,
}

fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../core/test/fixtures")
}

/// Extract the integer value of a top-level key from a small, known-shaped
/// JSON manifest (avoids pulling in serde_json).
fn json_u64(manifest: &str, key: &str) -> u64 {
    let needle = format!("\"{key}\"");
    let pos = manifest
        .find(&needle)
        .unwrap_or_else(|| panic!("manifest is missing key {key:?}"));
    manifest[pos + needle.len()..]
        .split_once(':')
        .expect("malformed value for key")
        .1
        .trim_start()
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse()
        .expect("non-integer value for key")
}

/// Split a BE-u32 length-prefixed frame stream into full wire frames.
fn read_frames(path: &Path) -> Vec<Vec<u8>> {
    let bytes = fs::read(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let mut frames = Vec::new();
    let mut off = 0;
    while off < bytes.len() {
        let len = u32::from_be_bytes(bytes[off..off + 4].try_into().unwrap()) as usize;
        off += 4;
        frames.push(bytes[off..off + len].to_vec());
        off += len;
    }
    assert_eq!(off, bytes.len(), "trailing bytes after last frame");
    frames
}

/// Verify the 30-byte wire header of a DATA frame and return its payload (the
/// RaptorQ packet). `expected_esi` is the ESI the header must carry; repair
/// frames carry ESI >= K', so pass `None` to skip that check.
fn frame_packet(frame: &[u8], expected_esi: Option<u32>) -> &[u8] {
    assert_eq!(&frame[0..4], b"QRDF", "frame magic is not QRDF");
    assert_eq!(frame[5], 0x01, "frame type byte is not DATA (0x01)");
    let esi = u32::from_le_bytes(frame[14..18].try_into().unwrap());
    if let Some(want) = expected_esi {
        assert_eq!(esi, want, "frame ESI mismatch");
    }
    let block_len = u32::from_le_bytes(frame[22..26].try_into().unwrap()) as usize;
    assert_eq!(
        frame.len(),
        30 + block_len + 4,
        "frame header+payload+crc length"
    );
    &frame[30..30 + block_len]
}

/// Parse and wire-verify one fixture directory.
fn load_fixture(name: &'static str) -> Fixture {
    let dir = fixtures_dir().join(name);
    let manifest = fs::read_to_string(dir.join("manifest.json"))
        .unwrap_or_else(|e| panic!("read manifest: {e}"));
    let mtu = json_u64(&manifest, "mtu") as u16;
    let k = json_u64(&manifest, "k") as usize;
    let compressed_size = json_u64(&manifest, "compressedSize") as usize;

    let payload =
        fs::read(dir.join("payload.bin")).unwrap_or_else(|e| panic!("read payload.bin: {e}"));
    assert_eq!(payload.len(), compressed_size, "{name}: payload.bin size");

    let source_packets = read_frames(&dir.join("data.frames"))
        .iter()
        .enumerate()
        .map(|(i, frame)| {
            let packet = frame_packet(frame, Some(i as u32));
            assert_eq!(packet.len() as u16, mtu, "packet {i} len != mtu");
            EncodingPacket::deserialize(packet)
        })
        .collect::<Vec<_>>();
    assert_eq!(source_packets.len(), k, "{name}: source packet count");

    let repair_packets = read_frames(&dir.join("repair.frames"))
        .iter()
        .map(|frame| EncodingPacket::deserialize(frame_packet(frame, None)))
        .collect::<Vec<_>>();
    assert!(!repair_packets.is_empty(), "{name}: no repair packets");

    Fixture {
        name,
        payload,
        source_packets,
        repair_packets,
        mtu,
    }
}

/// The decoder config: transfer length is the encoder input (== payload.bin),
/// bounded by the wire MTU; `with_defaults` derives the same symbol size
/// (mtu - 4 header bytes) and source-block split the PWA encoder used.
fn decoder_config(fx: &Fixture) -> ObjectTransmissionInformation {
    ObjectTransmissionInformation::with_defaults(fx.payload.len() as u64, fx.mtu)
}

/// Rebuild a packet with its ESI shifted by `delta` — normalizes the PWA's
/// v1.7.x repair ESIs (K' + i) to the v2.0.1 convention (kt + i).
fn relabel(packet: &EncodingPacket, delta: u32) -> EncodingPacket {
    EncodingPacket::new(
        PayloadId::new(
            packet.payload_id().source_block_number(),
            packet.payload_id().encoding_symbol_id() - delta,
        ),
        packet.data().to_vec(),
    )
}

fn feed_until_complete(decoder: &mut Decoder, packets: &[EncodingPacket]) -> Option<Vec<u8>> {
    for packet in packets {
        if let Some(decoded) = decoder.decode(packet.clone()) {
            return Some(decoded);
        }
    }
    None
}

/// Feed packets in order to a fresh Decoder until the payload is reassembled.
fn decode_all(fx: &Fixture, packets: &[EncodingPacket]) -> Vec<u8> {
    feed_until_complete(&mut Decoder::new(decoder_config(fx)), packets)
        .unwrap_or_else(|| panic!("{}: decoder never completed", fx.name))
}

/// Feed source packets under a deterministic loss pattern, then `repair`
/// packets, until the payload is reassembled. Returns the decoded bytes and
/// how many source packets were dropped.
fn decode_with_loss(fx: &Fixture, repair: &[EncodingPacket]) -> (Vec<u8>, usize) {
    let config = decoder_config(fx);
    // Drop every `step`-th source packet (step 5 = 20% loss); the fixtures ship
    // only 20 repair frames, so `step` grows until the budget absorbs the loss.
    for step in 5..=fx.source_packets.len() + 5 {
        let mut decoder = Decoder::new(config);
        let mut dropped = 0;
        let mut decoded = None;
        for (i, packet) in fx.source_packets.iter().enumerate() {
            if i % step == 0 {
                dropped += 1;
            } else if let Some(bytes) = decoder.decode(packet.clone()) {
                decoded = Some(bytes);
                break;
            }
        }
        decoded = decoded.or_else(|| feed_until_complete(&mut decoder, repair));
        if let Some(bytes) = decoded {
            return (bytes, dropped);
        }
    }
    panic!(
        "{}: repair budget cannot absorb even a 1-packet loss",
        fx.name
    );
}

const FIXTURES: [&str; 3] = ["random-1k", "random-64k", "text-256k"];

#[test]
fn pwa_source_packets_decode_byte_identical() {
    // Given: fixtures produced by the PWA's real pipeline (wasm raptorq v1.7.24).
    for name in FIXTURES {
        let fx = load_fixture(name);
        // When: every source packet from data.frames is fed to a crate v2.0.1
        // Decoder in order.
        let decoded = decode_all(&fx, &fx.source_packets);
        // Then: the reassembled bytes equal the exact encoder input.
        assert_eq!(
            decoded, fx.payload,
            "{}: PWA-packet interop decode mismatch",
            fx.name
        );
    }
}

#[test]
fn pwa_packets_decode_with_loss_via_relabeled_repair() {
    // The PWA's repair DATA is byte-correct: relabeling its ESI from the
    // v1.7.x convention (K' + i) to the v2.0.1 convention (kt + i) makes the
    // crate decoder reassemble the payload byte-identical after a real loss.
    for name in FIXTURES {
        let fx = load_fixture(name);
        let offset =
            fx.repair_packets[0].payload_id().encoding_symbol_id() - fx.source_packets.len() as u32;
        let relabeled: Vec<EncodingPacket> = fx
            .repair_packets
            .iter()
            .map(|p| relabel(p, offset))
            .collect();
        let (decoded, dropped) = decode_with_loss(&fx, &relabeled);
        assert!(
            dropped > 0,
            "{}: loss variant dropped no source packets",
            fx.name
        );
        assert_eq!(
            decoded, fx.payload,
            "{}: relabeled-repair decode mismatch",
            fx.name
        );
    }
}

#[test]
fn pwa_repair_packets_as_encoded_expose_esi_regression() {
    // FINDING (interop blocker): raptorq 2.0.1 changed the repair-packet ESI
    // on the wire from K' + i (RFC 6330, and v1.7.x/wasm) to kt + i, and its
    // decoder compensates by adding (K' - kt) before computing the encoding
    // tuple. A v2.0.1 Decoder fed the PWA's repair packets (ESI = K' + i)
    // looks up tuple ESI 2K' - kt + i and reconstructs garbage or never
    // completes. The source-symbol path is unaffected (raw data), which is why
    // pwa_source_packets_decode_byte_identical passes. This test pins the
    // regression precisely: it fails loudly if a crate upgrade fixes it.
    for name in FIXTURES {
        let fx = load_fixture(name);
        let kt = fx.source_packets.len() as u32;
        let kprime = fx.repair_packets[0].payload_id().encoding_symbol_id();
        let offset = kprime - kt;

        // Field-level proof: the crate's repair packet labeled ESI (kt + i)
        // carries the same symbol data as the PWA's packet labeled ESI (K' + i)
        // — the entire difference is the ESI value, not the symbol bytes.
        let encoder = Encoder::new(&fx.payload, decoder_config(&fx));
        let crate_packets = encoder.get_encoded_packets(20);
        for (i, pwa) in fx.repair_packets.iter().enumerate() {
            let crate_match = crate_packets
                .iter()
                .find(|p| p.payload_id().encoding_symbol_id() == kt + i as u32);
            let Some(crate_match) = crate_match else {
                panic!("{}: crate emitted no repair packet at ESI kt+{i}", fx.name);
            };
            assert_eq!(
                crate_match.data(),
                pwa.data(),
                "repair data at corrected ESI"
            );
        }

        // Visible consequence: feeding the PWA repair packets as encoded cannot
        // reassemble the payload (wrong tuple per ESI).
        let (decoded, dropped) = decode_with_loss(&fx, &fx.repair_packets);
        assert!(
            dropped > 0,
            "{}: loss variant dropped no source packets",
            fx.name
        );
        assert_ne!(
            decoded, fx.payload,
            "{}: PWA repair packets (ESI K'+i) unexpectedly decoded byte-identical \
             under v2.0.1; the ESI regression is fixed — update this contract \
             and the interop claim (offset was K'-kt = {offset})",
            fx.name
        );
    }
}

#[test]
fn crate_self_round_trip_is_byte_identical() {
    // Encoder::with_defaults over payload.bin reproduces the PWA's partitioning
    // (same OTI defaults); get_encoded_packets(0) yields the source packets.
    // A fresh Decoder over the crate's own packets must round-trip, independent
    // of the FFI wrapper.
    for name in FIXTURES {
        let fx = load_fixture(name);
        let encoder = Encoder::with_defaults(&fx.payload, fx.mtu);
        let packets = encoder.get_encoded_packets(0);
        let decoded = decode_all(&fx, &packets);
        assert_eq!(
            decoded, fx.payload,
            "{}: crate self round-trip mismatch",
            fx.name
        );
    }
}

#[test]
fn packet_header_layout_matches_wire_spec() {
    // The RaptorQ packet inside each DATA frame is `[SBN u8][ESI BE24] +
    // symbol bytes`, length == mtu — identical header layout across the PWA's
    // wasm raptorq v1.7 and the crate v2.0.1 (the repair-ESI *values* differ;
    // see pwa_repair_packets_as_encoded_expose_esi_regression).
    for name in FIXTURES {
        let fx = load_fixture(name);
        let frames = read_frames(&fixtures_dir().join(name).join("data.frames"));
        let packet = &frames[0][30..30 + fx.mtu as usize];
        assert_eq!(
            packet.len(),
            fx.mtu as usize,
            "{}: packet length != mtu",
            fx.name
        );
        assert_eq!(packet[0], 0x00, "{}: first source packet SBN != 0", fx.name);
        let esi = (u32::from(packet[1]) << 16) | (u32::from(packet[2]) << 8) | u32::from(packet[3]);
        assert_eq!(esi, 0, "{}: first source packet ESI (BE24) != 0", fx.name);
        // Every parsed source packet's payload ID matches its frame index.
        for (i, packet) in fx.source_packets.iter().enumerate() {
            let id = packet.payload_id();
            assert_eq!(id.source_block_number(), 0, "{}: packet {i} SBN", fx.name);
            assert_eq!(
                id.encoding_symbol_id() as usize,
                i,
                "{}: packet {i} ESI",
                fx.name
            );
        }
    }
}
