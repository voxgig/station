<?php

/**
 * Error codes follow the SDKs' house grammar (design station.md 14):
 * <subject>_<condition>, absence as no_<thing>, gates as _allow.
 * The `errors` corpus section pins the exact strings.
 *
 * A port of typescript/src/error.ts, which is canonical.
 */

declare(strict_types=1);

namespace Voxgig\Station;

const CODES = [
    'station_no_proxy',
    'station_secret_no_value',
    'station_secret_error',
    'station_secret_name',
    'station_host_allow',
    'station_grant_expired',
    'station_wrap_order',
    'station_protocol',
    'station_no_plugin',
    'station_no_entity',
    'station_no_op',
    'station_agent_allow',
    'station_body_limit',
    'station_replay_lossy',
    'station_open_conflict',
    'station_bound_twice',
];

class StationError extends \RuntimeException
{
    public string $stationCode;

    public function __construct(string $code, string $message)
    {
        parent::__construct($code . ': ' . $message);
        $this->stationCode = $code;
    }

    public function code(): string
    {
        return $this->stationCode;
    }
}

function known_code(string $code): bool
{
    return in_array($code, CODES, true);
}
