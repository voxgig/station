// ignore_for_file: non_constant_identifier_names

import 'package:voxgig_station/voxgig_station.dart';

import '../base/BaseFeature.dart';

// Binds this SDK to a voxgig/station control surface: registration,
// wire-truth http events, and placeholder credential injection. Thin by
// design - all logic it calls lives in the station library (station
// design 2); featureBinding resolves the station from the feature
// options or the ambient instance, verifies wrap position, registers,
// and wraps the transport. No station open -> null binding, and the
// feature is an inert no-op (station design 3.1).
class StationFeature extends BaseFeature {
  FeatureBinding? _binding;

  StationFeature() {
    version = '0.0.1';
    name = 'station';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    _binding = featureBinding(ctx, opts);
    return null;
  }

  @override
  dynamic PrePoint(dynamic ctx) {
    _binding?.prePoint(ctx);
    return null;
  }

  @override
  dynamic PreDone(dynamic ctx) {
    _binding?.preDone(ctx);
    return null;
  }

  @override
  dynamic PreUnexpected(dynamic ctx) {
    _binding?.preUnexpected(ctx);
    return null;
  }
}
