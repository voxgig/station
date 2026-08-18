# ProjectName SDK station feature

from __future__ import annotations

from projectname_sdk.feature.base_feature import ProjectNameBaseFeature

from voxgig_station import feature_binding


# Binds this SDK to a voxgig/station control surface: registration,
# wire-truth http events, and placeholder credential injection. Thin by
# design - all logic it calls lives in the station library (station
# design §2); feature_binding resolves the station from the feature
# options or the ambient instance, verifies wrap position, registers,
# and wraps the transport. No station open -> None binding, and the
# feature is an inert no-op (station design §3.1).
class ProjectNameStationFeature(ProjectNameBaseFeature):
    def __init__(self):
        super().__init__()
        self.version = "0.0.1"
        self.name = "station"
        self.active = True
        self._binding = None

    def init(self, ctx, options):
        self._binding = feature_binding(ctx, options)

    def PrePoint(self, ctx):
        if self._binding is not None:
            self._binding.PrePoint(ctx)

    def PreDone(self, ctx):
        if self._binding is not None:
            self._binding.PreDone(ctx)

    def PreUnexpected(self, ctx):
        if self._binding is not None:
            self._binding.PreUnexpected(ctx)
