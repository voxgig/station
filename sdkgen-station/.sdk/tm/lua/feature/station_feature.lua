-- ProjectName SDK station feature
--
-- Binds this SDK to a voxgig/station control surface: registration,
-- wire-truth http events, and placeholder credential injection. Thin by
-- design - all logic it calls lives in the station library (station
-- design 2); station.feature_binding resolves the station from the
-- feature options or the ambient instance, verifies wrap position,
-- registers, and wraps the transport. No station open -> nil binding,
-- and the feature is an inert no-op (station design 3.1).
--
-- The station library rides VENDORED beside this file, at
-- feature/station/voxgig_station.lua - no voxgig-station rock exists on
-- LuaRocks to declare in the rockspec, and a dependency on a
-- nonexistent package would break every install. Its canonical source
-- is the voxgig/station repo's lua/ port; the copy here is refreshed by
-- the sdkgen-station package, so never edit it in a generated project
-- (add is overwrite).

local BaseFeature = require("feature.base_feature")

-- The vendored copy first (it ships inside this SDK); an installed
-- voxgig_station module second, so a published rock can take over
-- without an adapter change.
local station_ok, station = pcall(require, "feature.station.voxgig_station")
if not station_ok then
  station = require("voxgig_station")
end

local StationFeature = {}
StationFeature.__index = StationFeature
setmetatable(StationFeature, { __index = BaseFeature })


function StationFeature.new()
  local self = setmetatable(BaseFeature.new(), StationFeature)
  self.version = "0.0.1"
  self.name = "station"
  self.active = true
  self._binding = nil
  return self
end


function StationFeature:init(ctx, options)
  self._binding = station.feature_binding(ctx, options)
end


-- Hook bridge (station design 3 item 3): operation semantics correlated
-- with the HTTP events via the per-op id on the SDK's own ctx.

function StationFeature:PrePoint(ctx)
  if self._binding ~= nil then
    self._binding.PrePoint(ctx)
  end
end

function StationFeature:PreDone(ctx)
  if self._binding ~= nil then
    self._binding.PreDone(ctx)
  end
end

function StationFeature:PreUnexpected(ctx)
  if self._binding ~= nil then
    self._binding.PreUnexpected(ctx)
  end
end


return StationFeature
