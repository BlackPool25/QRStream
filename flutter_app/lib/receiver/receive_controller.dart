/// App-scoped receive-session state — the persistence seam that keeps a
/// completed transfer on screen.
///
/// The receive view owns the transient decode machinery (camera, FrameBuffer,
/// reassembler, live stats) but writes every session transition into this
/// controller, which lives in the app shell for the shell's whole lifetime.
/// Tab switches and the 600dp breakpoint rebuild both dispose the view's
/// State; the controller — bound to the view on each creation — keeps the
/// completed session (phase == saved with the SaveResult) alive across them.
/// It is also the sink for the process-death restore path: the receive view
/// pushes the restored saved-file metadata back in after state restoration.
library;

import 'package:flutter/foundation.dart';
import 'package:qr_data_transfer/receiver/saver.dart';
import 'package:qr_transfer_core/receiver/reassembler.dart'
    show ReassemblyResult;

/// The high-level stage of a receive session.
enum ReceivePhase { idle, starting, scanning, saving, saved, error }

/// Owns the persistent session state of a receive flow. Views bind to it with
/// [ChangeNotifier.addListener] and render from its getters.
class ReceiveSessionController extends ChangeNotifier {
  ReceivePhase _phase = ReceivePhase.idle;
  SaveResult? _saved;
  ReassemblyResult? _result;
  bool _verified = false;
  String? _error;

  /// The current stage of the session.
  ReceivePhase get phase => _phase;

  /// The verified reassembly once [setVerified] has run (still in the
  /// scanning stage — the save card sits over the camera feed).
  ReassemblyResult? get result => _result;

  /// The completed save once [setSaved] has run; renders the saved card.
  SaveResult? get saved => _saved;

  /// Whether the whole-file SHA-256 gate passed for [result].
  bool get verified => _verified;

  /// The failure banner / error-card message, when set.
  String? get error => _error;

  /// Enters the scanning stage. [error] may carry a transient failure (e.g. a
  /// failed save) to show as a banner while the scan keeps running.
  void setScanning({String? error}) {
    _phase = ReceivePhase.scanning;
    _error = error;
    notifyListeners();
  }

  /// Records the verified reassembly; the stage stays [ReceivePhase.scanning]
  /// so the save card appears over the camera feed.
  void setVerified(ReassemblyResult result) {
    _verified = true;
    _result = result;
    notifyListeners();
  }

  /// Enters the saving stage.
  void setSaving() {
    _phase = ReceivePhase.saving;
    notifyListeners();
  }

  /// Records the completed save; the saved card renders from here on.
  void setSaved(SaveResult saved) {
    _saved = saved;
    _phase = ReceivePhase.saved;
    notifyListeners();
  }

  /// A hard failure — the error card (e.g. the camera could not start).
  void setError(String message) {
    _error = message;
    _phase = ReceivePhase.error;
    notifyListeners();
  }

  /// Clears the whole session back to idle.
  void reset() {
    _phase = ReceivePhase.idle;
    _saved = null;
    _result = null;
    _verified = false;
    _error = null;
    notifyListeners();
  }
}
