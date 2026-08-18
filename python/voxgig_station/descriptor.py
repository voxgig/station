# The descriptor normalizer and canonical serializer (design station.md 4).
#
# A port of typescript/src/descriptor.ts, which is canonical.

import json
import re

_ENVTOKEN_RE = re.compile(r'[^A-Z0-9]+')


def envtoken(name):
    """The ONLY way to build an env-var token in station, mirroring sdkgen's
    packageMeta envToken exactly: 'gnarly-pets' -> 'GNARLY_PETS'. The
    `secretname` corpus section pins the round-trip against sekreto's
    envkey() and sdkgen's envName() - the one place three grammars meet."""
    return _ENVTOKEN_RE.sub('_', str(name or '').upper()).strip('_')


def secretname_default(slug):
    """The default sekreto name for a plugin (design station.md 5.1):
    envtoken(slug) lowercased, plus '.apikey'. sekreto's envkey() then
    yields exactly the env var the SDK's README documents:
    gnarly_pets.apikey -> GNARLY_PETS_APIKEY."""
    return envtoken(slug).lower() + '.apikey'


def _legacy_slug(name):
    # Best-effort slug from a camel name, for SDKs whose embedded config
    # predates main.slug (design station.md 4 legacy sentinels). The hyphen
    # caveat is real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT
    # 'voxgig-solardemo' - callers surface a warning event when this path
    # is taken.
    return str(name or '').lower()


def normalize_descriptor(config, active_features=None):
    """Normalize a generated SDK's embedded config into descriptor v1
    (design station.md 4). The config is the one every SDK carries
    (config main / feature / options / entity); the descriptor is a VIEW
    over it. Returns (descriptor, warnings)."""
    warnings = []
    config = config if isinstance(config, dict) else {}
    main = config.get('main') or {}
    options = config.get('options') or {}

    name = str(main.get('name') or '')
    slug = main.get('slug')
    if slug is None or '' == slug:
        slug = _legacy_slug(name)
        warnings.append(
            'descriptor: legacy config has no main.slug; derived "' + slug +
            '" from the camel name - hyphens in the original name are lost')

    version = str(main['version']) if main.get('version') is not None else '0.0.0'
    target = str(main['target']) if main.get('target') is not None else 'unknown'

    server = []
    svr = options.get('server') or {}
    for k in sorted(svr.keys()):
        server.append({'name': k, 'value': str(svr[k])})

    auth_active = options.get('auth') is not None
    auth = {
        'active': auth_active,
        'prefix': str(options['auth'].get('prefix') or '') if auth_active else '',
        'secretname': secretname_default(slug),
    }

    entities = {}
    entdefs = config.get('entity') or {}
    for ename in sorted(entdefs.keys()):
        e = entdefs[ename] or {}
        fields = {}
        for f in e.get('fields') or []:
            if isinstance(f, dict) and f.get('name') is not None:
                fields[f['name']] = {'kind': str(f.get('kind') or f.get('type') or '')}
        ops = {}
        opdefs = e.get('op') or {}
        for opname in sorted(opdefs.keys()):
            op = opdefs[opname] or {}
            points = []
            for p in op.get('points') or []:
                if p is None:
                    continue
                point = {
                    'method': str(p.get('method') or ''),
                    'path': str(p.get('orig') or p.get('path') or ''),
                    'params': [s[1:] for s in (p.get('parts') or [])
                               if isinstance(s, str) and s.startswith(':')],
                }
                if p.get('select') is not None:
                    point['select'] = p['select']
                points.append(point)
            ops[opname] = {'points': points}
        entities[ename] = {'fields': fields, 'ops': ops}

    features = []
    fdefs = config.get('feature') or {}
    factive = active_features or {}
    for fname in sorted(fdefs.keys()):
        fao = factive.get(fname)
        features.append({
            'name': fname,
            'active': isinstance(fao, dict) and True is fao.get('active'),
        })

    descriptor = {
        'station': 1,
        'name': name,
        'slug': slug,
        'envtoken': envtoken(slug),
        'version': version,
        'target': target,
        'base': str(options.get('base') or ''),
        'server': server,
        'auth': auth,
        'entities': entities,
        'features': features,
    }

    return descriptor, warnings


def canonical_serialize(value):
    """Canonical serialization (design station.md 4): UTF-8, object keys
    sorted bytewise, no insignificant whitespace, minimal JSON escaping.
    The proxy dedupes registrations by a hash of this, so every language
    must produce identical bytes - the `canonical` corpus section carries
    the adversarial cases."""
    if value is None or value is True or value is False:
        return json.dumps(value)
    if isinstance(value, str):
        # ensure_ascii=False keeps non-ASCII literal, exactly like
        # JSON.stringify's minimal escaping in the reference.
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (int, float)):
        return json.dumps(value)
    if isinstance(value, (list, tuple)):
        return '[' + ','.join(canonical_serialize(v) for v in value) + ']'
    if isinstance(value, dict):
        # Bytewise sort: compare UTF-8 byte sequences, not code points
        # (identical for str keys, but stated as the rule).
        keys = sorted(value.keys(), key=lambda k: str(k).encode('utf-8'))
        return '{' + ','.join(
            json.dumps(str(k), ensure_ascii=False) + ':' +
            canonical_serialize(value[k]) for k in keys) + '}'
    return 'null'
