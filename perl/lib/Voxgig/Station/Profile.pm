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

    my %plugin;
    for my $src ( $base->{plugin}, $overlay->{plugin} ) {
        next unless _ismap($src);
        for my $slug ( keys %$src ) {
            next unless _ismap( $src->{$slug} );
            $plugin{$slug} =
              { %{ $plugin{$slug} || {} }, %{ $src->{$slug} } };
        }
    }

    # A configured secret name sekreto would reject is caught at profile
    # load, not first request (design station.md 14 station_secret_name).
    for my $slug ( sort keys %plugin ) {
        my $name = $plugin{$slug}{secret};
        next if !defined $name;
        next if Voxgig::Sekreto::validname($name);

        Voxgig::Station::Error::fail( 'station_secret_name',
            'profile "' . $profile_name . '" plugin "' . $slug
              . '": secret name rejected by sekreto: '
              . ( ref $name ? '(ref)' : '"' . $name . '"' ) );
    }

    return { name => $profile_name, providers => $providers, plugin => \%plugin };
}

1;
