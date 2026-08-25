package Voxgig::Station::Loader;

# The loader (design station.md 6.3), where the language allows it.
#
# In ts, js, py, rb, php, PERL, lua, elixir and clojure a module can be
# loaded by name at runtime, so `api.<slug>.package` closes the loop:
# station loads the package (which triggers self-registration, 6.2 path
# 1) and then looks up the factory.
#
# THREE PERL-SPECIFIC MAPPINGS, all forced by the language rather than
# chosen, and none of them a divergence from the contract:
#
#  - THERE IS ONE MODULE SYSTEM. `require` is synchronous and so is
#    `sdk()`, so the ts/js CommonJS-vs-ESM split - `load_async` and the
#    `await station.load()` preload it exists for - has no counterpart
#    here. `Voxgig::Station::load` is kept as a synchronous preload of
#    the declared packages; nothing needs it before `sdk()`.
#  - `require` returns a truth value, not a module object, so the
#    "module" a factory is read off is a PACKAGE NAME. `export` names a
#    class in it (or a top-level one, which is what sdkgen's perl target
#    emits: `TaskpadSDK`).
#  - the name is turned into a path for `require` (`A::B` -> `A/B.pm`)
#    rather than passed through a string eval, so nothing from a config
#    file is ever compiled as perl source.
#
# ONE STANDING LIMIT, and it is the perl target's rather than this
# module's: a generated Perl SDK is a FILE TREE loaded by absolute path,
# not a CPAN distribution, so `package` only resolves when the
# application has put that tree on @INC (`use lib`). Where it has not,
# 6.2's paths 1 and 2 - self-registration and Station->provide - are the
# ones that work, and README.md says so.
#
# THIS IS A CODE-LOADING SURFACE DRIVEN BY A CONFIG FILE, so it has
# rules, and they are enforced here rather than documented and hoped
# for. See check_package and Voxgig::Station::loader_package.
#
# A port of typescript/src/loader.ts, which is canonical.

use strict;
use warnings;

use Scalar::Util ();

use Voxgig::Station::Descriptor qw(canonical_serialize);
use Voxgig::Station::Error ();
use Voxgig::Station::Factory qw(factory_for provide);

use Exporter 'import';
our @EXPORT_OK = qw(
  DEFAULT_EXPORT camelify check_package factory_from_module load_async load_sync
);

# The fixed alias every generated package exports.
#
# `export` defaults to this rather than to a derived class name because
# it is the same identifier in every generated package, where
# camelify(slug).'SDK' is a rule that has to be recomputed and can be
# wrong. The derived name is the SECOND attempt and an explicit `export`
# the third. `package` has NO default: a guessed package name that
# resolves to the wrong thing is worse than a required key.
use constant DEFAULT_EXPORT => 'SDK';

# `stripe-eu` -> `StripeEu`, for the second-attempt export name.
sub camelify {
    my ($slug) = @_;
    my @parts = grep { '' ne $_ } split( /[^A-Za-z0-9]+/, defined $slug ? "$slug" : '' );
    return join( '', map { ucfirst $_ } @parts );
}

# Only MODULE NAMES, resolved by the host language's ordinary resolution
# from the application root (@INC). Never a filesystem path, never a
# URL, never anything relative - a config file naming a path is a config
# file reaching outside the dependency graph it is allowed to name.
sub check_package {
    my ( $api, $pkg ) = @_;
    my $p = defined $pkg ? "$pkg" : '';

    # A TRAVERSAL SEGMENT IS NOT A LEADING MARKER, and checking only the
    # first character misses it: `pkg/../../escape` starts with neither
    # `.` nor `/`, so a first-character check passes it, and the host
    # resolves it from outside the named dependency. The whole point of
    # this function is that a configured package stays inside the
    # dependency graph a reviewer can see.
    my $seg = grep { '.' eq $_ || '..' eq $_ } split( m{/}, $p, -1 );

    my $bad =
         '' eq $p
      || 0 == index( $p, '.' )
      || 0 == index( $p, '/' )
      || 0 == index( $p, '~' )
      || $seg
      || 0 <= index( $p, '://' )
      || 0 <= index( $p, "\\" );

    if ($bad) {
        Voxgig::Station::Error::fail( 'station_sdk_load',
            'api "' . ( defined $api ? $api : '' )
              . '": `package` must be a module name resolved from the '
              . 'application root, not a path or URL: '
              . canonical_serialize($pkg) );
    }
    return $p;
}

# Build a `{construct, config}` pair from a module that self-registered
# nothing - the retrofit path for a package whose SDK predates the
# station feature. It is NOT descriptor-blind: a generated main module
# exports its constructor AND the `config` singleton beside it.
sub factory_from_module {
    my ( $api, $module, $exportname ) = @_;
    $module = defined $module ? "$module" : '';

    my @tried;
    my $pick = sub {
        my ($name) = @_;
        for my $class ( _classnames( $module, $name ) ) {
            push @tried, $class;
            return $class if _canconstruct($class);
        }
        return undef;
    };

    my $ctor;
    $ctor = $pick->($exportname)
      if defined $exportname && !ref $exportname && '' ne $exportname;
    $ctor = $pick->(DEFAULT_EXPORT) unless defined $ctor;
    $ctor = $pick->( camelify($api) . 'SDK' ) unless defined $ctor;

    if ( !defined $ctor ) {
        Voxgig::Station::Error::fail( 'station_sdk_load',
            'api "' . ( defined $api ? $api : '' )
              . '": no SDK constructor found on the module; tried ['
              . join( ', ', @tried )
              . ']. Set `export` to the exported name.' );
    }

    my $config = _moduleconfig($module);
    $config = _moduleconfig($ctor) unless defined $config;
    if ( !defined $config ) {
        Voxgig::Station::Error::fail( 'station_sdk_load',
            'api "' . ( defined $api ? $api : '' )
              . '": the module exports a constructor but no `config` '
              . 'singleton, so its feature schema and transport roles cannot '
              . 'be read before construction (6.2)' );
    }

    return {
        construct => sub { return $ctor->new( $_[0] ) },
        config    => $config,
    };
}

# A perl "export" is a CLASS NAME, and a generated perl SDK puts its
# class at the top level (`TaskpadSDK`) while a hand-written one may
# nest it under the package. Both spellings are tried, in that order,
# and both are recorded so the failure message names what was looked
# for. A name already carrying `::` is taken as written.
sub _classnames {
    my ( $module, $name ) = @_;
    return () unless defined $name && !ref $name && '' ne $name;
    return ($name) if 0 <= index( $name, '::' );
    return ( $name, $module . '::' . $name ) if '' ne $module;
    return ($name);
}

sub _canconstruct {
    my ($class) = @_;
    return 0 unless defined $class && '' ne $class;
    return 0 unless $class =~ /^[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*$/;
    return $class->can('new') ? 1 : 0;
}

# `config`, then `CONFIG` - the sub spelling first, because a generated
# perl package exposes its embedded config through a sub and a
# hand-written one usually as a package variable. Looked for on the
# package and then on the constructor class, which in perl IS a package.
sub _moduleconfig {
    my ($holder) = @_;
    return undef
      unless defined $holder
      && '' ne $holder
      && $holder =~ /^[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*$/;

    if ( my $sub = $holder->can('config') ) {
        my $out = eval { $sub->($holder) };
        return $out if ref($out) eq 'HASH';
        $out = eval { $sub->() };
        return $out if ref($out) eq 'HASH';
    }

    no strict 'refs';
    for my $name ( 'config', 'CONFIG' ) {
        my $scalar = ${ $holder . '::' . $name };
        return $scalar if ref($scalar) eq 'HASH';
        my $hash = \%{ $holder . '::' . $name };
        return $hash if keys %$hash;
    }
    return undef;
}

# Synchronous load. Returns true when the api has a factory afterwards -
# either because loading the package triggered self-registration, or
# because one was built from its exports.
sub load_sync {
    my ( $api, $pkg, $exportname ) = @_;
    my $module = check_package( $api, $pkg );
    return 1 if defined factory_for($api);

    my $file = $module;
    $file =~ s{::}{/}g;
    $file .= '.pm' unless $file =~ /\.pm\z/;

    my $ok = eval { require $file; 1 };
    if ( !$ok ) {
        my $err = $@;

        # A package that self-registers a CONFLICTING factory is its own
        # error, told in its own words.
        die $err
          if Scalar::Util::blessed($err)
          && $err->isa('Voxgig::Station::StationError');

        my $msg = "$err";
        $msg =~ s/\s+\z//;
        Voxgig::Station::Error::fail( 'station_sdk_load',
            'api "' . ( defined $api ? $api : '' ) . '": package "' . $module
              . '" could not be imported: ' . $msg );
    }

    # Path 1: the package self-registered while being loaded.
    return 1 if defined factory_for($api);

    provide( $api, factory_from_module( $api, $module, $exportname ) );
    return 1;
}

# Perl has ONE module system, so the async counterpart is the same flow
# through the same `require`. It exists so the surface is the one the
# contract names, and so a caller written against the ts/js shape works
# unchanged; there is no second loading mode for it to reach.
sub load_async {
    my ( $api, $pkg, $exportname ) = @_;
    return load_sync( $api, $pkg, $exportname );
}

1;
