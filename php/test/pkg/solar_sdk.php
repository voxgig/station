<?php

/**
 * A stand-in for a GENERATED SDK PACKAGE, for the design 6.3 loader.
 *
 * It is deliberately reached only through class autoloading: test/run.php
 * registers an spl_autoload_register for the `Acme\SolarSdk\` prefix and
 * never requires this file, so `load_sync` has to resolve
 * `Acme\SolarSdk\SDK` the way php resolves any class - which is the
 * mechanism this port's loader claims to use.
 *
 * The two halves 6.2 requires are both here: the constructor, under the
 * fixed `SDK` alias every generated package exports, and the `config`
 * singleton beside it.
 */

declare(strict_types=1);

namespace Acme\SolarSdk;

const config = \Voxgig\Station\Test\SDKCONFIG;

class SDK extends \Voxgig\Station\Test\FakeSDK
{
}
