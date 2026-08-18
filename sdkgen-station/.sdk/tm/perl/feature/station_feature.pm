# ProjectName SDK station feature
#
# Binds this SDK to a voxgig/station control surface: registration,
# wire-truth http events, and placeholder credential injection. Thin by
# design - all logic it calls lives in the station library (station
# design §2); Voxgig::Station::Adapter::feature_binding resolves the
# station from the feature options or the ambient instance, verifies
# wrap position, registers, and wraps the transport. No station open ->
# undef binding, and the feature is an inert no-op (station design §3.1).
#
# The station library rides VENDORED beside this file, under
# feature/station/lib/ - generated Perl SDKs load everything by absolute
# file path, never from an installed @INC (the vendored Voxgig::Struct
# precedent), and no Voxgig::Station distribution exists on CPAN to name
# in PREREQ_PM. Its canonical source is the voxgig/station repo's perl/
# port; the copy here is refreshed by the sdkgen-station package, so
# never edit it in a generated project (add is overwrite).

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/base_feature.pm"));
require(Cwd::abs_path("$__dir/station/lib/Voxgig/Station.pm"));

package ProjectNameStationFeature;

our @ISA = ('ProjectNameBaseFeature');

sub new {
  my ($class) = @_;
  my $self = ProjectNameBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'station';
  $self->{active} = 1;
  $self->{_binding} = undef;
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{_binding} = Voxgig::Station::Adapter::feature_binding($ctx, $options);
  return;
}

# Hook bridge (station design §3 item 3): operation semantics correlated
# with the HTTP events via the per-op id on the SDK's own ctx.

sub PrePoint {
  my ($self, $ctx) = @_;
  $self->{_binding}->PrePoint($ctx) if $self->{_binding};
  return;
}

sub PreDone {
  my ($self, $ctx) = @_;
  $self->{_binding}->PreDone($ctx) if $self->{_binding};
  return;
}

sub PreUnexpected {
  my ($self, $ctx) = @_;
  $self->{_binding}->PreUnexpected($ctx) if $self->{_binding};
  return;
}

1;
