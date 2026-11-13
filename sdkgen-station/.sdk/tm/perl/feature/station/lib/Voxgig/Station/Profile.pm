package Voxgig::Station::Profile;

# station.json lookup and profile resolution (design station.md 3.5).
#
# A port of typescript/src/profile.ts, which is canonical. Voxgig::Sekreto
# (for validname) is located and loaded by Voxgig::Station's bootstrap
# before this module is used.

use strict;
use warnings;
use utf8;

use Cwd ();
use Encode ();
use File::Basename ();
use File::Spec ();
use JSON::PP ();

use Voxgig::Station::Descriptor ();

use Voxgig::Station::Error ();
use Voxgig::Station::Shape qw(BLOCK_DEFAULTS);
use Voxgig::Station::Struct qw(jsonform struct_parse);

use Exporter 'import';
our @EXPORT_OK = qw(
  block_of config_scope find_config_file instance_options load_config
  parse_config refapi resolve_profile select_profile
);

sub _ismap { return ref( $_[0] ) eq 'HASH' ? 1 : 0 }

# station.json lookup: cwd upward to the repo root, then
# ~/.voxgig/station.json (design station.md 3.5). A repo root is where
# .git lives; with no repo the walk stops at the filesystem root.
sub find_config_file {
    my ($from) = @_;
    my $dir = File::Spec->rel2abs( defined $from ? $from : Cwd::getcwd() );

    while (1) {
        my $candidate = File::Spec->catfile( $dir, 'station.json' );
        return $candidate if -e $candidate;

        my $at_repo_root = -e File::Spec->catfile( $dir, '.git' );
        my $parent       = File::Basename::dirname($dir);
        last if $at_repo_root || $parent eq $dir;
        $dir = $parent;
    }

    my $home = defined $ENV{HOME} ? $ENV{HOME} : ( getpwuid($<) )[7];
    return undef unless defined $home && '' ne $home;
    my $homefile = File::Spec->catfile( $home, '.voxgig', 'station.json' );
    return -e $homefile ? $homefile : undef;
}

sub load_config {
    my ($from) = @_;
    my $file = find_config_file($from);
    return undef unless defined $file;

    open( my $handle, '<', $file )
      or Voxgig::Station::Error::fail( 'station_no_plugin',
        'cannot read station.json: ' . $file );
    local $/ = undef;
    my $bytes = <$handle>;
    close($handle);

    # RFC 8259 8.1: the text is UTF-8. A byte order mark stays in the
    # text, where the JSON parse refuses it.
    my $text = eval { Encode::decode( 'UTF-8', $bytes, Encode::FB_CROAK ) };
    Voxgig::Station::Error::fail( 'station_config_invalid',
        'station.json at ' . $file . ' is not UTF-8' )
      unless defined $text;
    return parse_config( $text, $file );
}

# A file that is not JSON is a CONFIG error, not a raw parse error
# escaping open(). Decoders disagree about an unpaired surrogate escape,
# which I-JSON forbids, so the text is scanned before it is decoded.
#
# Read through struct's own JSON reader, not JSON::PP's, for ONE reason:
# it keeps map key order, and design 8.4's LAST tie-break of the feature
# order is the order the config declared its features in. A plain perl
# hash has no order at all, so JSON::PP would turn that tie-break into a
# per-process accident. `jsonform` then puts the tree back into this
# port's spelling (JSON::PP booleans, undef for null) with the ordering
# intact.
sub parse_config {
    my ( $text, $file ) = @_;
    my $where = 'station.json' . ( defined $file ? ' at ' . $file : '' );
    my $literal = unpaired_surrogate($text);
    Voxgig::Station::Error::fail( 'station_config_invalid',
        $where . ' has an unpaired surrogate escape in ' . $literal )
      if defined $literal;

    my $parsed = eval { jsonform( struct_parse($text) ) };
    if ( my $err = $@ ) {
        my $msg = "$err";
        $msg =~ s/ at \S+ line \d+\.?\n?\z//;
        $msg =~ s/\s+\z//;
        Voxgig::Station::Error::fail( 'station_config_invalid',
            $where . ' is not valid JSON: ' . $msg );
    }
    return $parsed;
}

# The first closed string literal, quotes included, holding a \u escape
# for a surrogate that is not half of an escaped pair.
sub unpaired_surrogate {
    my ($text)   = @_;
    my $start    = -1;
    my $unpaired = 0;
    for ( my $i = 0 ; $i < length $text ; $i++ ) {
        my $c = substr( $text, $i, 1 );
        if ( -1 == $start ) {
            if ( '"' eq $c ) {
                $start    = $i;
                $unpaired = 0;
            }
        }
        elsif ( '"' eq $c ) {
            return substr( $text, $start, $i + 1 - $start ) if $unpaired;
            $start = -1;
        }
        elsif ( '\\' eq $c ) {
            my $unit = _escaped_unit( $text, $i );
            if ( _high_surrogate($unit)
                && _low_surrogate( _escaped_unit( $text, $i + 6 ) ) )
            {
                $i += 11;
            }
            elsif ( _high_surrogate($unit) || _low_surrogate($unit) ) {
                $unpaired = 1;
                $i += 5;
            }
            else {
                $i++;
            }
        }
    }
    return undef;
}

sub _escaped_unit {
    my ( $text, $at ) = @_;
    return -1 if $at + 6 > length $text;
    my $escape = substr( $text, $at, 6 );
    return $escape =~ /\A\\u([0-9A-Fa-f]{4})\z/ ? hex($1) : -1;
}

sub _high_surrogate { return 0xD800 <= $_[0] && $_[0] <= 0xDBFF }

sub _low_surrogate { return 0xDC00 <= $_[0] && $_[0] <= 0xDFFF }

# Which side of the repo review boundary the discovered station.json
# came from (design station.md 6.3).
#
# `package` and `export` are honoured only from REPO-SCOPED config,
# because a user-level file sits outside the repo's review boundary and
# a `package` key arriving from it names CODE TO LOAD. Everything else
# in a user-level config still applies - this narrows one key rather
# than distrusting the file.
sub config_scope {
    my ($from) = @_;
    my $file = find_config_file($from);
    return 'none' unless defined $file;

    my $home = defined $ENV{HOME} ? $ENV{HOME} : ( getpwuid($<) )[7];
    return 'repo' unless defined $home && '' ne $home;

    my $homefile = File::Spec->catfile( $home, '.voxgig', 'station.json' );
    return $file eq $homefile ? 'user' : 'repo';
}

# Profile selection: the open() option, else VOXGIG_STATION_PROFILE, else
# 'default' (design station.md 3.5 - env vars rank above station.json but
# below open() opts; profile NAME selection follows the same order with
# open() opts winning).
sub select_profile {
    my ($opt_profile) = @_;
    return $opt_profile
      if defined $opt_profile && !ref $opt_profile && '' ne $opt_profile;

    my $env = $ENV{VOXGIG_STATION_PROFILE};
    return $env if defined $env && '' ne $env;

    return 'default';
}

sub _providers_of {
    my ($profile) = @_;
    return undef unless _ismap($profile) && _ismap( $profile->{secrets} );
    my $providers = $profile->{secrets}{providers};
    return ref($providers) eq 'ARRAY' ? $providers : undef;
}

# Merge the base profile ('default') with the selected overlay: deep-merge
# per plugin, EXCEPT secrets.providers which replaces wholesale (design
# station.md 3.5, 5.2 - chain order decides which store wins, so a
# positional merge would be actively dangerous). The `profile` corpus
# section pins this.
# The block-level defaults come from Voxgig::Station::Shape, which is
# the ONE table with TWO callers at DIFFERENT MOMENTS: validate_config
# applies it BEFORE, to every block, because a block with no present
# keys is an open map; this resolver applies it AFTER, to the merged
# instance, because an absent key must stay absent through the merge.
# Shape::MERGE_SENSITIVE names `active` explicitly for the same reason.

# The api half of a ref is the substring before the first `$`, and an
# untagged ref IS an api slug (design 3.4). LEXICAL, and that is the
# point: under the old free-form identity which api an instance used was
# itself a merged value, so a port that got the phasing wrong silently
# picked another api's defaults.
sub refapi {
    my ($ref) = @_;
    $ref = defined $ref ? "$ref" : '';
    my $at = index( $ref, '$' );
    return -1 == $at ? $ref : substr( $ref, 0, $at );
}

# Shallow merge, per key, left to right - each source over the one before
# it. An overlay's `policy` REPLACES the base's entirely rather than
# merging `hosts` into it; an allowlist that widens because two
# precedence levels merged is the failure this rule prevents.
sub _shallow {
    my %out;
    for my $src (@_) {
        next unless _ismap($src);
        %out = ( %out, %$src );
    }
    return \%out;
}

sub _sortedkeys {
    my %keys;
    for my $m (@_) {
        next unless _ismap($m);
        $keys{$_} = 1 for keys %$m;
    }
    return sort keys %keys;
}

# Merge the base profile ('default') with the selected overlay.
#
# Design 3.3's total order for the two block levels, lowest first:
#
#   base.api[<api>] + base.sdk[<ref>] + overlay.api[<api>] + overlay.sdk[<ref>]
#
# PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE FLAT
# LEFT-TO-RIGHT MERGE. It must not be reorganized into "collapse each
# namespace, then put instance over api" - that lets every instance value
# beat every api value, so a production `api.stripe.policy` would fail to
# override a default profile's `sdk.stripe$test.policy`, silently keeping
# the wider allowlist in production.
#
# `secrets.providers` replaces wholesale, never merges (3.5, 5.2).
sub resolve_profile {
    my ( $config, $profile_name ) = @_;

    my $profiles =
      _ismap($config) && _ismap( $config->{profiles} )
      ? $config->{profiles}
      : {};
    my $base = _ismap( $profiles->{default} ) ? $profiles->{default} : {};
    my $overlay =
      'default' eq $profile_name ? {}
      : ( _ismap( $profiles->{$profile_name} ) ? $profiles->{$profile_name} : {} );

    my $providers = _providers_of($overlay);
    $providers = _providers_of($base) unless defined $providers;
    $providers = [ { kind => 'env' } ] unless defined $providers;

    my $base_api = _ismap( $base->{api} )    ? $base->{api}    : {};
    my $over_api = _ismap( $overlay->{api} ) ? $overlay->{api} : {};
    my $base_sdk = _ismap( $base->{sdk} )    ? $base->{sdk}    : {};
    my $over_sdk = _ismap( $overlay->{sdk} ) ? $overlay->{sdk} : {};

    # The api-level defaults in effect for this profile. A REPORT, not an
    # input to the instance merge below.
    my %api;
    for my $slug ( _sortedkeys( $base_api, $over_api ) ) {
        $api{$slug} = _shallow( $base_api->{$slug}, $over_api->{$slug} );
    }

    # An api block declares no instance of its own (3.1), so the ref set
    # comes from the two `sdk` maps alone.
    my %sdk;
    for my $ref ( _sortedkeys( $base_sdk, $over_sdk ) ) {
        my $a = refapi($ref);
        my $merged = _shallow(
            $base_api->{$a}, $base_sdk->{$ref},
            $over_api->{$a}, $over_sdk->{$ref}
        );

        # Defaults are applied ONCE, to the fully merged instance. Had the
        # overlay block carried a synthesized `active` into the merge, a
        # one-key environment override would silently re-enable an
        # integration the base declared inactive.
        my %defaults = BLOCK_DEFAULTS();
        for my $k ( keys %defaults ) {
            $merged->{$k} = $defaults{$k}->() unless exists $merged->{$k};
        }

        $sdk{$ref} = $merged;
    }

    _checksecrets( \%sdk, $profile_name );

    return {
        name => $profile_name, providers => $providers,
        api  => \%api,        sdk       => \%sdk,
    };
}

# A configured secret name sekreto would reject is caught at profile
# load, not first request (14 station_secret_name) - and then the DERIVED
# names are checked for uniqueness, because envtoken is lossy: it
# collapses any run of non-alphanumerics to `_`, so `stripe$test` and an
# untagged instance of a `stripe-test` api both derive
# `stripe_test.apikey` and would silently share one credential.
#
# Two instances that EXPLICITLY name one secret are not a collision -
# that is the shared-key case the api-level `secret` exists for.
sub _checksecrets {
    my ( $sdk, $profile_name ) = @_;
    my @refs = sort keys %$sdk;

    for my $ref (@refs) {
        my $name = $sdk->{$ref}{secret};
        next if !defined $name;
        next if Voxgig::Sekreto::validname($name);

        Voxgig::Station::Error::fail( 'station_secret_name',
            'profile "' . $profile_name . '" sdk "' . $ref
              . '": secret name rejected by sekreto: '
              . ( ref $name ? '(ref)' : '"' . $name . '"' ) );
    }

    my %seen;
    for my $ref (@refs) {
        my $written = $sdk->{$ref}{secret};
        my $derived = !defined $written || '' eq $written;
        my $name =
          $derived ? Voxgig::Station::Descriptor::secretname_default($ref) : $written;

        if ( exists $seen{$name} && ( $derived || $seen{$name}[1] ) ) {
            Voxgig::Station::Error::fail( 'station_secret_collision',
                'profile "' . $profile_name . '": instances "' . $seen{$name}[0]
                  . '" and "' . $ref . '" both resolve to secret name "' . $name
                  . '", so they would share one credential; name it explicitly '
                  . 'on each, or at the api level to share it deliberately (§5.1)' );
        }
        $seen{$name} = [ $ref, $derived ] unless exists $seen{$name};
    }
    return;
}

# The block that governs an instance: its own, else its api's.
sub block_of {
    my ( $profile, $ref ) = @_;
    my $own = $profile->{sdk}{$ref};
    return defined $own ? $own : $profile->{api}{ refapi($ref) };
}

# 3.5 for a named instance: the block's `options`, then its `base`
# (steps 3-6), under the caller's options (step 9), per top-level key.
sub instance_options {
    my ( $block, $opts ) = @_;
    $block = {} unless ref($block) eq 'HASH';
    my $out = { %{ ref( $block->{options} ) eq 'HASH' ? $block->{options} : {} } };
    $out->{base} = $block->{base} if defined $block->{base};
    return { %$out, %{ ref($opts) eq 'HASH' ? $opts : {} } };
}

1;
