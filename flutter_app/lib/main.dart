import 'package:flutter/material.dart';

import 'package:qr_transfer_core/codec/raptorq_bridge.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ensureRustLib();
  runApp(const QrTransferApp());
}
