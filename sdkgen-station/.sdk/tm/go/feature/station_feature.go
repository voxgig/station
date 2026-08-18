package feature

import (
	station "github.com/voxgig/station/go/station"

	"GOMODULE/core"
)

// Binds this SDK to a voxgig/station control surface: registration,
// wire-truth http events, and placeholder credential injection. Thin by
// design - all logic it calls lives in the station library (station
// design §2); station.Bind resolves the station from the feature
// options or the ambient instance, verifies wrap position, registers,
// and wraps the transport. No station open -> nil binding, and the
// feature is an inert no-op (station design §3.1). This file only
// translates the generated SDK's concrete types into the library's
// BindSpec seam - never restate a binding rule here.
type StationFeature struct {
	BaseFeature
	binding *station.FeatureBinding
}

func NewStationFeature() *StationFeature {
	return &StationFeature{
		BaseFeature: BaseFeature{
			Version: "0.0.1",
			Name:    "station",
			Active:  true,
		},
	}
}

func (f *StationFeature) Init(ctx *core.Context, options map[string]any) {
	client := ctx.Client
	utility := ctx.Utility

	// The wrap-position guard reads the client's feature list by name
	// (station design §3.3; Go funcs cannot carry a wrap marker).
	names := make([]string, 0, len(client.Features))
	for _, added := range client.Features {
		names = append(names, added.GetName())
	}

	// The wrap must land on the LIVE utility instance (GetUtility()
	// returns a copy), and the inner transport is whatever is current
	// at init time - test's mock, or a prior feature's wrap.
	inner := utility.Fetcher

	f.binding = station.Bind(&station.BindSpec{
		Client:       client,
		Config:       ctx.Config,
		SDKOptions:   ctx.Options,
		FeatureOpts:  options,
		FeatureNames: names,
		Mode:         func() string { return client.Mode },
		Fetch: func(opctx any, fullurl string, fetchdef map[string]any) (any, error) {
			fctx, _ := opctx.(*core.Context)
			return inner(fctx, fullurl, fetchdef)
		},
		SetFetch: func(next station.TransportFunc) {
			utility.Fetcher = func(fctx *core.Context, fullurl string,
				fetchdef map[string]any) (any, error) {
				return next(fctx, fullurl, fetchdef)
			}
		},
	})
}

// Hook bridge (station design §3 item 3): operation semantics correlated
// with the HTTP events via the op's own context value.

func (f *StationFeature) PrePoint(ctx *core.Context) {
	if f.binding != nil {
		f.binding.PrePoint(ctx)
	}
}

func (f *StationFeature) PreDone(ctx *core.Context) {
	if f.binding != nil {
		f.binding.PreDone(ctx, stationOpInfo(ctx))
	}
}

func (f *StationFeature) PreUnexpected(ctx *core.Context) {
	if f.binding != nil {
		f.binding.PreUnexpected(ctx, stationOpInfo(ctx))
	}
}

// stationOpInfo reads the op identity and outcome from the SDK context -
// the one extraction Go's typing keeps out of the library.
func stationOpInfo(ctx *core.Context) station.OpInfo {
	info := station.OpInfo{Outcome: "unknown"}
	if ctx.Op != nil {
		if "_" != ctx.Op.Entity {
			info.Entity = ctx.Op.Entity
		}
		if "_" != ctx.Op.Name {
			info.Op = ctx.Op.Name
		}
	}
	if "" == info.Entity && ctx.Entity != nil {
		info.Entity = ctx.Entity.GetName()
	}
	if ctx.Result != nil {
		if ctx.Result.Err != nil || !ctx.Result.Ok {
			info.Outcome = "err"
		} else {
			info.Outcome = "ok"
		}
	}
	return info
}
