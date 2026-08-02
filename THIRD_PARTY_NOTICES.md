# Third-Party Notices

QRStream is licensed under the MIT License (see [LICENSE](LICENSE)). This file
credits the third-party components bundled or distributed with QRStream, as
required by their licenses.

## Apache License 2.0 components

The following components are distributed under the
[Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0).
QRStream reproduces their license terms; the license text is available at the
URL above. No NOTICE files are carried by these components.

| Component                                             | Purpose                                                     | Version     |
| ----------------------------------------------------- | ----------------------------------------------------------- | ----------- |
| [raptorq](https://github.com/cberner/raptorq)         | RaptorQ fountain codec (Rust)                               | 2.0.1       |
| [zxing-cpp](https://github.com/zxing-cpp/zxing-cpp)   | QR/barcode decoding (C++, via the `zxing-cpp` Rust wrapper) | 0.5.3       |
| [zxing-wasm](https://github.com/zxing-cpp/zxing-wasm) | QR decoding for the PWA build (WebAssembly)                 | (PWA build) |

## MIT License components

The following components are distributed under the MIT License:

| Component                                                                            | Purpose                         |
| ------------------------------------------------------------------------------------ | ------------------------------- |
| [@ribpay/qr-code-generator](https://www.npmjs.com/package/@ribpay/qr-code-generator) | QR matrix encoding              |
| [pako](https://github.com/nodeca/pako)                                               | DEFLATE compression (PWA build) |
| [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge)                | Rust ↔ Dart FFI bridge          |

## BSD-3-Clause components

| Component                                         | Purpose                 |
| ------------------------------------------------- | ----------------------- |
| [Flutter SDK](https://github.com/flutter/flutter) | UI framework and engine |

## Generated from

This notice was generated from the project's declared dependencies
(`pubspec.yaml`, `Cargo.toml`, `package.json`). Run the platform tooling
(`flutter pub deps --licenses`, `cargo about`) to regenerate a full
machine-audited list before any release.
