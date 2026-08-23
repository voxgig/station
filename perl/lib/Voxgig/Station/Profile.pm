package Voxgig::Station::Profile;

# station.json lookup and profile resolution (design station.md 3.5).
#
# A port of typescript/src/profile.ts, which is canonical. Voxgig::Sekreto
# (for validname) is located and loaded by Voxgig::Station's bootstrap
# before this module is used.

use strict;
use warnings;

use Cwd ();
use File::Basename ();
use File::Spec ();
use JSON::PP ();

use Voxgig::Station::Descriptor ();

use Voxgig::Station::Error ();

use Exporter 'import';
our @EXPORT_OK = qw(
  find_config_file load_config resolve_profile select_profile
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
    my $text = <$handle>;
    close($handle);
    return JSON::PP->new->decode($text);
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
# The one block key carrying the timing rule: applied AFTER the merge,
# never before (design 3.3, 4.2).
our @MERGE_SENSITIVE = ('active');

# `active` must be a real JSON boolean, not a truthy scalar: the corpus
# compares the resolved instance by value, and perl's 1 serializes as a
# number where every other port emits `true`.
sub _block_defaults { return ( active => JSON::PP::true, feature => {} ); }

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
        my %defaults = _block_defaults();
        for my $k ( keys %defaults ) {
            $merged->{$k} = $defaults{$k} unless exists $merged->{$k};
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
                  . 'on each, or at the api level to share it deliberately (5.1)' );
        }
        $seen{$name} = [ $ref, $derived ] unless exists $seen{$name};
    }
    return;
}

1;
