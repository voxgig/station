package Voxgig::Station::Descriptor;

# The descriptor normalizer and canonical serializer (design station.md 4):
# a VIEW over the embedded config every generated SDK carries - never a
# second model. Legacy configs (no main.slug/version/target) get fixed
# sentinels plus a warning.
#
# A port of typescript/src/descriptor.ts, which is canonical. All data is
# string-keyed, matching the generated SDKs' config hashes and the
# conformance corpus. Perl scalars are untyped ('5' vs 5 indistinguishable
# by eye) and JSON booleans are objects, so the serializer leans on
# JSON::PP's SV-flag scalar encoding and emits booleans for anything
# boolean-shaped - including the vendored struct utility's TO_JSON-capable
# sentinels - rather than ever guessing from a string.

use strict;
use warnings;

use JSON::PP ();
use Scalar::Util qw(blessed);

use Exporter 'import';
our @EXPORT_OK = qw(
  canonical_serialize envtoken normalize_descriptor secretname_default
);

# The ONLY way to build an env-var token in station, mirroring sdkgen's
# packageMeta envToken exactly: 'gnarly-pets' -> 'GNARLY_PETS'. The
# `secretname` corpus section pins the round-trip against sekreto's
# envkey() and sdkgen's envName() - the one place three grammars meet.
sub envtoken {
    my ($name) = @_;
    my $token = defined $name && !ref $name ? uc "$name" : '';
    $token =~ s/[^A-Z0-9]+/_/g;
    $token =~ s/^_+|_+$//g;
    return $token;
}

# The default sekreto name for a plugin (design station.md 5.1):
# envtoken(slug) lowercased, plus '.apikey'. sekreto's envkey() then
# yields exactly the env var the SDK's README documents:
# gnarly_pets.apikey -> GNARLY_PETS_APIKEY.
sub secretname_default {
    my ($slug) = @_;
    return lc( envtoken($slug) ) . '.apikey';
}

# Best-effort slug from a camel name, for SDKs whose embedded config
# predates main.slug (design station.md 4 legacy sentinels). The hyphen
# caveat is real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT
# 'voxgig-solardemo' - callers surface a warning event when this path is
# taken.
sub legacy_slug {
    my ($name) = @_;
    return defined $name && !ref $name ? lc "$name" : '';
}

sub _ismap  { return ref( $_[0] ) eq 'HASH' ? 1 : 0 }
sub _islist { return ref( $_[0] ) eq 'ARRAY' ? 1 : 0 }

# A defined, non-empty plain string.
sub _str {
    my ($val) = @_;
    return defined $val && !ref $val ? "$val" : '';
}

# Is this value boolean-true? Handles JSON::PP booleans, the vendored
# struct utility's blessed booleans (both overload 'bool'), and plain
# scalars; non-boolean references never count as true.
sub _truthy {
    my ($val) = @_;
    return 0 if !defined $val;
    if ( ref $val ) {
        return ( $val ? 1 : 0 ) if blessed($val);
        return 0;
    }
    return $val ? 1 : 0;
}

# Normalize a generated SDK's embedded config into descriptor v1 (design
# station.md 4). Returns ( \%descriptor, \@warnings ).
sub normalize_descriptor {
    my ( $config, $active_features ) = @_;

    my @warnings;
    $config = {} unless _ismap($config);
    my $main    = _ismap( $config->{main} )    ? $config->{main}    : {};
    my $options = _ismap( $config->{options} ) ? $config->{options} : {};

    my $name = _str( $main->{name} );
    my $slug = $main->{slug};
    if ( !defined $slug || ( !ref $slug && '' eq $slug ) ) {
        $slug = legacy_slug($name);
        push @warnings,
          'descriptor: legacy config has no main.slug; derived "' . $slug
          . '" from the camel name - hyphens in the original name are lost';
    }
    $slug = _str($slug);

    my $version = defined $main->{version} ? _str( $main->{version} ) : '0.0.0';
    my $target  = defined $main->{target}  ? _str( $main->{target} )  : 'unknown';

    my @server;
    my $svr = _ismap( $options->{server} ) ? $options->{server} : {};
    for my $key ( sort keys %$svr ) {
        push @server, { name => $key, value => _str( $svr->{$key} ) };
    }

    my $auth_active = defined $options->{auth} ? 1 : 0;
    my $auth        = {
        active => $auth_active ? JSON::PP::true : JSON::PP::false,
        prefix => $auth_active
        ? _str( _ismap( $options->{auth} ) ? $options->{auth}{prefix} : '' )
        : '',
        secretname => secretname_default($slug),
    };

    my %entities;
    my $entdefs = _ismap( $config->{entity} ) ? $config->{entity} : {};
    for my $ename ( sort keys %$entdefs ) {
        my $ent = _ismap( $entdefs->{$ename} ) ? $entdefs->{$ename} : {};

        my %fields;
        for my $field ( @{ _islist( $ent->{fields} ) ? $ent->{fields} : [] } ) {
            next unless _ismap($field) && defined $field->{name};
            my $kind = defined $field->{kind} ? $field->{kind} : $field->{type};
            $fields{ $field->{name} } = { kind => _str($kind) };
        }

        my %ops;
        my $opdefs = _ismap( $ent->{op} ) ? $ent->{op} : {};
        for my $opname ( sort keys %$opdefs ) {
            my $op = _ismap( $opdefs->{$opname} ) ? $opdefs->{$opname} : {};
            my @points;
            for my $p ( @{ _islist( $op->{points} ) ? $op->{points} : [] } ) {
                next unless _ismap($p);
                my $path =
                  defined $p->{orig} && '' ne _str( $p->{orig} )
                  ? $p->{orig}
                  : $p->{path};
                my $point = {
                    method => _str( $p->{method} ),
                    path   => _str($path),
                    params => [
                        map  { substr( $_, 1 ) }
                        grep { defined $_ && !ref $_ && 0 == index( $_, ':' ) }
                          @{ _islist( $p->{parts} ) ? $p->{parts} : [] }
                    ],
                };
                $point->{select} = $p->{select} if defined $p->{select};
                push @points, $point;
            }
            $ops{$opname} = { points => \@points };
        }

        $entities{$ename} = { fields => \%fields, ops => \%ops };
    }

    my @features;
    my $fdefs   = _ismap( $config->{feature} ) ? $config->{feature} : {};
    my $factive = _ismap($active_features)     ? $active_features   : {};
    for my $fname ( sort keys %$fdefs ) {
        my $fopts = $factive->{$fname};
        push @features,
          {
            name   => $fname,
            active => ( _ismap($fopts) && _truthy( $fopts->{active} ) )
            ? JSON::PP::true
            : JSON::PP::false,
          };
    }

    my $descriptor = {
        station  => 1,
        name     => $name,
        slug     => $slug,
        envtoken => envtoken($slug),
        version  => $version,
        target   => $target,
        base     => _str( $options->{base} ),
        server   => \@server,
        auth     => $auth,
        entities => \%entities,
        features => \@features,
    };

    return ( $descriptor, \@warnings );
}

# Scalar encoding leans on JSON::PP: numbers by SV flags (never a string
# guess), minimal escaping matching JSON.stringify, booleans - including
# blessed TO_JSON-capable ones like the vendored struct utility's - as
# true/false, and unencodable values as null (allow_blessed).
my $SCALAR_JSON =
  JSON::PP->new->allow_nonref(1)->allow_blessed(1)->convert_blessed(1);

# Canonical serialization (design station.md 4): UTF-8, object keys sorted
# bytewise, no insignificant whitespace, minimal JSON escaping. The proxy
# dedupes registrations by a hash of this, so every language must produce
# identical bytes - the `canonical` corpus section carries the adversarial
# cases. Perl's sort compares strings by code point, which for decoded
# text equals UTF-8 bytewise order (UTF-8 preserves code-point order).
sub canonical_serialize {
    my ($value) = @_;

    return 'null' if !defined $value;

    my $r = ref $value;

    if ( '' eq $r ) {
        return $SCALAR_JSON->encode($value);
    }

    if ( 'ARRAY' eq $r ) {
        return '[' . join( ',', map { canonical_serialize($_) } @$value ) . ']';
    }

    if ( 'HASH' eq $r ) {
        return '{'
          . join( ',',
            map { $SCALAR_JSON->encode("$_") . ':' . canonical_serialize( $value->{$_} ) }
            sort keys %$value )
          . '}';
    }

    return ( $value ? 'true' : 'false' ) if JSON::PP::is_bool($value);

    if ( blessed($value) ) {
        my $out = eval { $SCALAR_JSON->encode($value) };
        return defined $out ? $out : 'null';
    }

    # Everything else (code refs, bare scalar refs) is not data: null,
    # like the canonical port's fall-through.
    return 'null';
}

1;
