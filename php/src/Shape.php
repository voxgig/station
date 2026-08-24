<?php

/**
 * The config grammar, as data (design station.md 4).
 *
 * TWO STEPS, AND THE FIRST IS WHAT MAKES THE SECOND HONEST.
 *
 * struct drops the unexpected-key check for a map whose spec node ends
 * up empty - "an empty spec object means the object can be open". An
 * optional key is `['$ONE','$NIL', spec]`, and when the data does not
 * carry that key the validator REMOVES it from the spec node. So a block
 * whose keys are all optional degenerates into an open map exactly when
 * the data has none of them, and `{"solar": {"bass": 1}}` validates
 * clean - the one property the whole exercise is for, silently absent in
 * the one case that matters.
 *
 * So: normalize_config materializes every documented default, and
 * validate_config then runs a shape WITH NO OPTIONAL CONTAINERS AT ALL.
 * After normalization every container is present, so the shape can
 * require them, so unexpected-key detection is live at every level and
 * every error names its path.
 *
 * A port of typescript/src/shape.ts, which is canonical. The php-only
 * wrinkle - an empty array is both `{}` and `[]` - is decided in
 * Kind.php and nowhere else.
 */

declare(strict_types=1);

namespace Voxgig\Station;

require_once __DIR__ . '/Error.php';
require_once __DIR__ . '/Descriptor.php';
require_once __DIR__ . '/Kind.php';
require_once __DIR__ . '/Sekreto.php';
require_once __DIR__ . '/Structhome.php';

// ---------------------------------------------------------------------
// The defaults tables - ONE table each, and BLOCK_DEFAULTS has two
// callers at different moments
// ---------------------------------------------------------------------

/**
 * Profile-level containers. Safe to materialize early either way: they
 * are containers, and a missing one merges as empty regardless.
 *
 * @return array<string, callable(): mixed>
 */
function profile_defaults(): array
{
    return [
        'secrets' => fn() => ['providers' => [['kind' => 'env']]],
        'api' => fn() => empty_map(),
        'sdk' => fn() => empty_map(),
        'feature' => fn() => empty_map(),
    ];
}

/**
 * Block-level. `feature` is a container and safe early.
 *
 * `active` IS NOT, and that is the whole timing rule: a default
 * synthesized into an OVERLAY block overwrites the base's real value and
 * silently reactivates an integration the base deliberately barred
 * (design 3.3). So the two consumers read this same table at different
 * moments - validate_config BEFORE, applied to every block, because a
 * block with no present keys is an open map; resolve_profile AFTER,
 * applied to the merged instance, because an absent key must stay absent
 * through the merge.
 *
 * @return array<string, callable(): mixed>
 */
function block_defaults(): array
{
    return [
        'active' => fn() => true,
        'feature' => fn() => empty_map(),
    ];
}

/**
 * The one block key carrying the timing rule. Named rather than
 * inferred, so a reader does not have to work out which of the two it
 * is, and so a port can assert it.
 */
const MERGE_SENSITIVE = ['active'];

// ---------------------------------------------------------------------
// normalize_config
// ---------------------------------------------------------------------

/**
 * Materialize every documented default, DEFENSIVELY: a node that is not
 * the kind it expects is left alone for validate to reject with a proper
 * message. Pure data-in/data-out, which is what makes it portable to
 * sixteen languages and expressible in the corpus.
 *
 * THE NORMALIZED FORM IS AN INPUT TO VALIDATION AND TO NOTHING ELSE -
 * resolve_profile keeps reading the RAW config.
 *
 * php note: a SYNTHESIZED empty map is written as `(object)[]` (see
 * Kind.php); validate_config plains it back to `[]` on the way out, so
 * the value a caller sees is ordinary php data.
 */
function normalize_config(mixed $raw): mixed
{
    if (!is_map($raw)) {
        return $raw;
    }
    $out = map_entries($raw);

    if (!array_key_exists('station', $out)) {
        $out['station'] = 1;
    }
    if (!array_key_exists('profiles', $out)) {
        $out['profiles'] = empty_map();
    }
    if (!is_map($out['profiles'])) {
        return $out;
    }

    $profiles = [];
    foreach (map_entries($out['profiles']) as $pname => $p) {
        if (!is_map($p)) {
            $profiles[$pname] = $p;
            continue;
        }
        $prof = map_entries($p);

        foreach (profile_defaults() as $k => $make) {
            if (!array_key_exists($k, $prof)) {
                $prof[$k] = $make();
            }
        }

        // A `secrets` written without `providers` still gets the chain.
        if (is_map($prof['secrets']) && !mhas($prof['secrets'], 'providers')) {
            $secrets = map_entries($prof['secrets']);
            $secrets['providers'] = [['kind' => 'env']];
            $prof['secrets'] = $secrets;
        }

        $prof['feature'] = normfeatures($prof['feature']);

        foreach (['api', 'sdk'] as $bkey) {
            if (!is_map($prof[$bkey] ?? null)) {
                continue;
            }
            $blocks = [];
            foreach (map_entries($prof[$bkey]) as $ref => $b) {
                if (!is_map($b)) {
                    $blocks[$ref] = $b;
                    continue;
                }
                $block = map_entries($b);
                foreach (block_defaults() as $k => $make) {
                    if (!array_key_exists($k, $block)) {
                        $block[$k] = $make();
                    }
                }
                $block['feature'] = normfeatures($block['feature']);
                $blocks[$ref] = $block;
            }
            $prof[$bkey] = rebuilt($blocks, $prof[$bkey]);
        }

        $profiles[$pname] = $prof;
    }
    $out['profiles'] = rebuilt($profiles, $out['profiles']);

    return $out;
}

/**
 * Per feature entry, at every level: `active` -> true.
 *
 * A FEATURE NAMED IN THE CONFIG IS ONE YOU ARE ASKING FOR. The SDK's own
 * default is `active: false` for all but `log`, and
 * `{"retry": {"retries": 3}}` plainly means "retry, with three
 * attempts". It also keeps the feature map closed, for the same reason
 * every other block needs one present key.
 *
 * Defensive like the rest: a non-map is returned untouched for validate
 * to reject by path.
 */
function normfeatures(mixed $f): mixed
{
    if (!is_map($f)) {
        return $f;
    }
    $out = [];
    foreach (map_entries($f) as $name => $entry) {
        if (is_map($entry) && !mhas($entry, 'active')) {
            $e = map_entries($entry);
            $e['active'] = true;
            $out[$name] = $e;
        } else {
            $out[$name] = $entry;
        }
    }
    return rebuilt($out, $f);
}

/**
 * A rebuilt map, keeping the SOURCE when nothing was rebuilt: php cannot
 * tell an empty map from an empty list, so the only honest answer for an
 * empty rebuild is the value that came in - a synthesized `(object)[]`
 * stays a map, a user-written `[]` stays a list for the shape to reject.
 */
function rebuilt(array $built, mixed $src): mixed
{
    return 0 < count($built) ? $built : $src;
}

// ---------------------------------------------------------------------
// validate_config
// ---------------------------------------------------------------------

/** Credential-shaped keys (design 5.2). `secret` is here AND is the one
 * exempt key - see secretvalue below; a blanket deny would reject the
 * very mechanism that keeps values out of the file. */
const CREDENTIAL_KEYS = [
    'apikey', 'auth', 'authorization', 'token',
    'secret', 'password', 'credential', 'bearer',
];

/** The suffix rule catches `access_key`, `X-Api-Token` and friends in
 * one rule rather than a growing list of spellings. */
const CREDENTIAL_SUFFIX = ['_KEY', '_TOKEN', '_SECRET', '_PASSWORD'];

/**
 * 5.2's backstop, and it is stated as one rather than as a grammar.
 * `Name::valid()` is a NAME grammar, not a credential filter: it rejects
 * uppercase, hyphens, `+`, `/` and `=`, so it excludes most real
 * credential formats - but a lowercase hex token passes it cleanly. A
 * character class cannot tell a name from a secret.
 *
 * A RUN bound, not a length bound: `acme_internal_billing_service.apikey`
 * is 36 characters and passes (runs of 4/8/7/7/6), which is the false
 * positive a naive length bound would produce.
 */
const RUN_BOUND = 24;

/** The `budget` keys, for the 4.4 unexpected-key check below. */
const BUDGET_KEYS = ['concurrency', 'rps'];

/** `spec/config-shape.json`, found by walking up from src - this port
 * runs from the repo like the javascript one, so it reads the artifact
 * every port reads rather than shipping a mirror. */
function config_shapefile(): string
{
    $dir = __DIR__;
    for ($i = 0; $i < 8; $i++) {
        $cand = $dir . '/spec/config-shape.json';
        if (file_exists($cand)) {
            return $cand;
        }
        $dir = dirname($dir);
    }
    throw new \RuntimeException('station: spec/config-shape.json not found');
}

/**
 * A FRESH DEEP COPY on every call: struct's validate CONSUMES the spec
 * it walks (it deletes satisfied `$ONE` branches as it goes), so handing
 * it the parsed constant twice would validate the second config against
 * a spec the first had already eaten. php array value semantics make the
 * return itself a deep copy of the cached parse.
 *
 * @return array<string, mixed>
 */
function config_shape(): array
{
    static $shape = null;
    if (null === $shape) {
        $text = file_get_contents(config_shapefile());
        if (false === $text) {
            throw new \RuntimeException('station: cannot read config-shape.json');
        }
        $shape = json_decode($text, true, 512, JSON_THROW_ON_ERROR);
    }
    return $shape;
}

/**
 * Normalize, then validate (design 4.2). Raises station_config_invalid
 * with EVERY struct error at once - an eighteen-instance config that
 * touches three of them must not die because the eighteenth has a typo'd
 * package name - then the 5.2 scans.
 *
 * The 4.4 workarounds are merged into the SAME throw as struct's own
 * errors: a struct new enough to reject a first-element gap itself
 * reports a DIFFERENT spelling ("to be one of ..."), and the corpus pins
 * the explicit one - so the pinned message is produced here either way,
 * and behavior is identical whatever struct version resolves.
 *
 * Takes the NORMALIZED form. Handing it a raw config is the mistake 4.2
 * exists to prevent, so callers go through normalize_config.
 */
function validate_config(mixed $normalized): mixed
{
    struct_load();

    $injdef = new \stdClass();
    $injdef->errs = [];
    \Voxgig\Struct\Struct::validate($normalized, config_shape(), $injdef);

    $errs = [];
    foreach ((array) $injdef->errs as $e) {
        $errs[] = (string) $e;
    }

    [$secrets, $reserved, $invalid] = scan_config($normalized);

    if (0 < count($errs) || 0 < count($invalid)) {
        throw new StationError('station_config_invalid',
            implode('; ', array_merge($errs, $invalid)) . renamehint($normalized));
    }
    if (0 < count($reserved)) {
        throw new StationError('station_feature_reserved', implode('; ', $reserved));
    }
    if (0 < count($secrets)) {
        throw new StationError('station_config_secret', implode('; ', $secrets));
    }

    return plain($normalized);
}

/**
 * `plugin` is REMOVED, not aliased (design 3.4) - a deprecated alias
 * would be a second grammar for one concept in sixteen ports. The shape
 * already rejects it as an unexpected key; this says WHAT TO RENAME,
 * because "unexpected key: plugin" alone does not, and the migration for
 * a single-instance project is exactly this one rename.
 */
function renamehint(mixed $cfg): string
{
    $profiles = is_map($cfg) ? mval($cfg, 'profiles') : null;
    $hit = [];
    foreach (map_entries(is_map($profiles) ? $profiles : []) as $pname => $prof) {
        if (is_map($prof) && mhas($prof, 'plugin')) {
            $hit[] = 'profiles.' . $pname;
        }
    }
    if (0 === count($hit)) {
        return '';
    }
    return '; rename `plugin` to `sdk` in ' . implode(', ', $hit) .
        ' - the keys are unchanged, an untagged ref IS an api slug (3.4)';
}

/**
 * The 5.2 scans, over the parts of the grammar that hold arbitrary data.
 * Everything else is closed by construction and needs no scan. Collects
 * rather than throws - validate_config owns the throw order.
 *
 * `profiles.<p>.secrets.providers` IS NOT SCANNED: provider blocks
 * legitimately carry an `auth` sub-map ({method, role}), and
 * config#twenty-sdk-fleet passes only because the scan does not reach
 * there.
 *
 * @return array{0: string[], 1: string[], 2: string[]}
 */
function scan_config(mixed $cfg): array
{
    $secrets = [];
    $reserved = [];
    $invalid = [];

    $profiles = is_map($cfg) ? mval($cfg, 'profiles') : null;
    foreach (map_entries(is_map($profiles) ? $profiles : []) as $pname => $prof) {
        if (!is_map($prof)) {
            continue;
        }
        $ppath = 'profiles.' . $pname;

        scan_features(mval($prof, 'feature'), $ppath . '.feature',
            $secrets, $reserved, $invalid);

        foreach (['api', 'sdk'] as $bkey) {
            $blocks = mval($prof, $bkey);
            if (!is_map($blocks)) {
                continue;
            }
            foreach (map_entries($blocks) as $ref => $block) {
                if (!is_map($block)) {
                    continue;
                }
                $bpath = $ppath . '.' . $bkey . '.' . $ref;

                // The block's own `secret` holds a NAME. resolve_profile
                // checks it again per instance (station_secret_name);
                // this catches it at open(), for the whole file at once.
                if (mhas($block, 'secret')) {
                    secretvalue(mval($block, 'secret'), $bpath . '.secret', $secrets);
                }

                // `options` is passthrough to a generated constructor,
                // so it is the one place a value can hide.
                scan(mval($block, 'options'), $bpath . '.options', $secrets, $reserved);
                scan_features(mval($block, 'feature'), $bpath . '.feature',
                    $secrets, $reserved, $invalid);

                // 4.4's explicit checks, applied where the shape cannot
                // reach, raising the same code the shape would - and
                // pinned in the corpus so each workaround is removed
                // deliberately when struct is fixed rather than
                // forgotten.
                check_policy(mval($block, 'policy'), $bpath . '.policy', $invalid);
            }
        }
    }

    return [$secrets, $reserved, $invalid];
}

/**
 * A feature map at any level. `station` is reserved: station composes
 * its own wrap and a config that reconfigures it is asking for a state
 * the ordering rules cannot express (design 8.4).
 *
 * (The 8.5 descriptor-derived checker is check_features in Feature.php -
 * a different function with a similar job, kept apart deliberately.)
 *
 * @param string[] $secrets
 * @param string[] $reserved
 * @param string[] $invalid
 */
function scan_features(mixed $f, string $path, array &$secrets,
    array &$reserved, array &$invalid): void
{
    if (!is_map($f)) {
        return;
    }
    foreach (map_entries($f) as $name => $entry) {
        $fpath = $path . '.' . $name;
        if ('station' === $name) {
            $reserved[] = $path . '.station is reserved: station composes its ' .
                'own wrap and it cannot be configured from station.json';
        }
        $order = is_map($entry) ? mval($entry, 'order') : null;
        if (is_map($order)) {
            first_element(mval($order, 'before'), $fpath . '.order.before', $invalid);
            first_element(mval($order, 'after'), $fpath . '.order.after', $invalid);
        }
        scan($entry, $fpath, $secrets, $reserved);
    }
}

/**
 * The policy block's 4.4 workarounds, in one place because they are one
 * class of gap: struct cannot check what its own defects hide.
 *
 * - `hosts`, `allow.op` and `allow.method` are `$CHILD` string lists, so
 *   element 0 escapes the shape (see first_element below).
 * - `budget` is a map whose keys are ALL optional scalars, and struct
 *   removes an unsatisfied optional key from the spec node - so
 *   `budget: {rp: 1}` degenerates the spec into an open map and the typo
 *   passes. `allow` does not have this problem (its `$CHILD` keys stay
 *   in the spec whether or not the data carries them, keeping the map
 *   closed), and neither does `policy` itself (`hosts` anchors it);
 *   `budget` alone needs the explicit unexpected-key check, phrased as
 *   struct would phrase it.
 *
 * @param string[] $invalid
 */
function check_policy(mixed $policy, string $path, array &$invalid): void
{
    if (!is_map($policy)) {
        return;
    }

    first_element(mval($policy, 'hosts'), $path . '.hosts', $invalid);

    $allow = mval($policy, 'allow');
    if (is_map($allow)) {
        first_element(mval($allow, 'op'), $path . '.allow.op', $invalid);
        first_element(mval($allow, 'method'), $path . '.allow.method', $invalid);
    }

    $budget = mval($policy, 'budget');
    if (is_map($budget)) {
        $unknown = [];
        foreach (array_keys(map_entries($budget)) as $k) {
            if (!in_array((string) $k, BUDGET_KEYS, true)) {
                $unknown[] = (string) $k;
            }
        }
        sort($unknown, SORT_STRING);
        if (0 < count($unknown)) {
            $invalid[] = 'Unexpected keys at field ' . $path . '.budget: ' .
                implode(', ', $unknown);
        }
    }
}

/**
 * Design 4.4: `$CHILD` in LIST mode DOES NOT VALIDATE ELEMENT 0.
 * Verified: `["a", 1]` fails at index 1, `[1]` passes, at any list
 * length. An upstream struct defect, filed as voxgig/struct#113.
 *
 * It reaches THREE string lists in this shape: `policy.hosts`, and the
 * per-feature `order.before` / `order.after`. Applied where the shape
 * cannot reach, raising the same code the shape would, and PINNED IN THE
 * CORPUS so the workaround is removed deliberately when struct is fixed
 * rather than forgotten.
 *
 * @param string[] $invalid
 */
function first_element(mixed $list, string $path, array &$invalid): void
{
    if (!is_listv($list) || 0 === count($list)) {
        return;
    }
    if (is_string($list[0])) {
        return;
    }
    $invalid[] = 'Expected field ' . $path . '.0 to be string, but found ' .
        kindof_shape($list[0]) . ': ' . jsonify($list[0]);
}

/**
 * Recursive over EVERY nested map and list, not just the top level - a
 * credential one level down is the case a top-level scan misses
 * (corpus config#options-scan-is-recursive pins options.deep.list.0.apikey).
 *
 * @param string[] $secrets
 * @param string[] $reserved
 */
function scan(mixed $node, string $path, array &$secrets, array &$reserved): void
{
    if (is_listv($node) && 0 < count($node)) {
        foreach ($node as $i => $item) {
            scan($item, $path . '.' . $i, $secrets, $reserved);
        }
        return;
    }
    if (is_string($node)) {
        userinfo($node, $path, $secrets);
        return;
    }
    if (!is_map($node)) {
        return;
    }

    foreach (map_entries($node) as $key => $val) {
        $key = (string) $key;
        $kpath = $path . '.' . $key;

        // Design 8.6: station owns feature composition, so an
        // `options.feature` in a declarative config is a second,
        // unreconciled ordering input.
        if ('feature' === $key) {
            $reserved[] = $kpath . ' is reserved: configure features under ' .
                'the block\'s own `feature` key, not through `options`';
            continue;
        }

        if ('secret' === strtolower($key)) {
            secretvalue($val, $kpath, $secrets);
            continue;
        }

        if (credentialkey($key)) {
            $secrets[] = $kpath . ' is a credential-shaped key: station.json ' .
                'holds secret NAMES, never values (5.2)';
            continue;
        }

        scan($val, $kpath, $secrets, $reserved);
    }
}

function credentialkey(string $key): bool
{
    $low = preg_replace('/[^a-z0-9]+/', '', strtolower($key)) ?? '';
    if (in_array($low, CREDENTIAL_KEYS, true)) {
        return true;
    }
    $tok = envtoken($key);
    foreach (CREDENTIAL_SUFFIX as $suffix) {
        if (str_ends_with($tok, $suffix)) {
            return true;
        }
    }
    return false;
}

/**
 * A `secret`-named key holds a NAME, and that exemption is not a
 * loophole - it is the whole design. THREE checks, in this order, first
 * failure wins, and they live in the same handful of lines precisely so
 * a port cannot implement only the first and inherit the gaps the others
 * close.
 *
 * @param string[] $secrets
 */
function secretvalue(mixed $val, string $path, array &$secrets): void
{
    if (!is_string($val)) {
        $secrets[] = $path . ' must be a secret name (a string), but found ' .
            kindof_shape($val);
        return;
    }
    sekreto_load();
    if (!\Voxgig\Sekreto\Name::valid($val)) {
        $secrets[] = $path . ' is not a valid sekreto name, so it cannot be ' .
            'a name and must not be a value: ' . jsonify($val);
        return;
    }
    if (1 === preg_match('/[A-Za-z0-9]{' . RUN_BOUND . ',}/', $val)) {
        $secrets[] = $path . ' contains an unbroken alphanumeric run of ' .
            RUN_BOUND . ' or more characters, which is not a name anybody writes';
    }
}

/**
 * One rule about VALUES rather than keys, because the `proxy` feature
 * makes it concrete: `http://user:pass@proxy.internal:8080`. Parsed by
 * hand rather than through parse_url, so the rule is the same handful of
 * characters in every port; a parse failure is not an error.
 *
 * @param string[] $secrets
 */
function userinfo(string $val, string $path, array &$secrets): void
{
    if (1 !== preg_match('/^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\//', $val)) {
        return;
    }
    $at = strpos($val, '://');
    if (false === $at) {
        return;
    }
    $rest = substr($val, $at + 3);
    $authority = substr($rest, 0, strcspn($rest, '/?#'));
    $last = strrpos($authority, '@');
    if (false === $last || 0 === $last) {
        return;
    }
    $secrets[] = $path . ' is a URL carrying userinfo, which puts a ' .
        'credential in the config file; use the proxy feature\'s `fromEnv` ' .
        'option instead (8.6)';
}

/**
 * The SHAPE kindof, which must agree with struct's own spellings. NOT
 * the same function as Feature.php's kindof_feature, and they are not to
 * be unified: this one says "object"/"integer"/"decimal" because struct
 * does, that one says "map"/"number" because the 8.5 messages do.
 */
function kindof_shape(mixed $val): string
{
    if (null === $val) {
        return 'null';
    }
    if (is_listv($val)) {
        return 'list';
    }
    if (is_int($val)) {
        return 'integer';
    }
    if (is_float($val)) {
        return floor($val) === $val ? 'integer' : 'decimal';
    }
    if (is_map($val)) {
        return 'object';
    }
    if (is_bool($val)) {
        return 'boolean';
    }
    if (is_string($val)) {
        return 'string';
    }
    return strtolower(gettype($val));
}
