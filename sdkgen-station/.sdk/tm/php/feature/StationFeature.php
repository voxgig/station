<?php
declare(strict_types=1);

// ProjectName SDK station feature

require_once __DIR__ . '/BaseFeature.php';

// Binds this SDK to a voxgig/station control surface: registration,
// wire-truth http events, and placeholder credential injection. Thin by
// design - all logic it calls lives in the station library (station
// design §2); \Voxgig\Station\feature_binding resolves the station from
// the feature options or the ambient instance, verifies wrap position,
// registers, and wraps the transport. No station open -> null binding,
// and the feature is an inert no-op (station design §3.1).
//
// The voxgig/station library is this SDK's composer dependency
// (voxgig/station); class_exists() lets composer's autoloader load it on
// first use. When the library is not loadable at all no station can have
// been opened either, so the inert no-op is exact - nothing is emitted
// and nothing fails.
class ProjectNameStationFeature extends ProjectNameBaseFeature
{
    public mixed $_binding = null;

    public function __construct()
    {
        parent::__construct();
        $this->version = '0.0.1';
        $this->name = 'station';
        $this->active = true;
    }

    public function init(ProjectNameContext $ctx, array $options): void
    {
        if (!class_exists('\\Voxgig\\Station\\Station')) {
            return;
        }
        $this->_binding = \Voxgig\Station\feature_binding($ctx, $options);
    }

    // Hook bridge (station design §3 item 3): operation semantics
    // correlated with the HTTP events via the per-op id on the SDK's own
    // ctx.

    public function PrePoint(ProjectNameContext $ctx): void
    {
        $this->_binding?->PrePoint($ctx);
    }

    public function PreDone(ProjectNameContext $ctx): void
    {
        $this->_binding?->PreDone($ctx);
    }

    public function PreUnexpected(ProjectNameContext $ctx): void
    {
        $this->_binding?->PreUnexpected($ctx);
    }
}
