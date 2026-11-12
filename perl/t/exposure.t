# RUN: prove -Ilib -It t/exposure.t
#
# A port of typescript/test/exposure.test.ts, which is canonical.

use strict;
use warnings;

use Data::Dumper ();
use Scalar::Util qw(blessed reftype);
use Test::More;

use Voxgig::Station;

my $SECRET = 'exposure-key-101';

my $CONFIG = {
    main    => { name => 'taskpad', slug => 'taskpad', version => '1.0.0', target => 'perl' },
    options => { base => 'http://api.test', auth => { prefix => '' } },
    entity  => {},
};

# An SDK generated without the station feature, reduced to what the
# carried adapter touches: the options kept as given, extend features
# initialised in order, and a transport that answers 200.
{

    package ExposureSDK;

    sub new {
        my ( $class, $options ) = @_;
        my $self = bless { mode => 'live', features => [], options => $options }, $class;
        $self->{utility} = { fetcher => sub { return ( { status => 200, headers => {} }, undef ) } };
        $self->{ctx} = {
            client  => $self,
            utility => $self->{utility},
            options => $options,
            config  => $CONFIG,
        };
        for my $f ( @{ $options->{extend} || [] } ) {
            push @{ $self->{features} }, $f;
            $f->init( $self->{ctx}, ( $options->{feature} || {} )->{ $f->get_name } || {} );
        }
        return $self;
    }

    sub call {
        my ($self) = @_;
        return $self->{utility}{fetcher}->( $self->{ctx}, 'http://api.test/todo',
            { method => 'GET', headers => { authorization => $self->{options}{apikey} } } );
    }
}

sub shows {
    my ($value) = @_;
    return Data::Dumper->new( [$value] )->Indent(1)->Sortkeys(1)->Dump;
}

sub reaches_station {
    my ( $value, $seen ) = @_;
    $seen ||= {};
    return 0 unless ref $value;
    return 1 if blessed($value) && $value->isa('Voxgig::Station');
    return 0 if $seen->{$value}++;
    my $type = reftype($value);
    return ( grep { reaches_station( $_, $seen ) } values %$value ) ? 1 : 0 if 'HASH' eq $type;
    return ( grep { reaches_station( $_, $seen ) } @$value ) ? 1 : 0 if 'ARRAY' eq $type;
    return 0;
}

subtest 'a bound client\'s options hold no secret after a live request' => sub {
    Voxgig::Station->reset;
    local $ENV{TASKPAD_APIKEY} = $SECRET;
    my $st     = Voxgig::Station->open( { config => undef } );
    my $client = $st->connect( 'ExposureSDK', {} );
    my ( $res, $err ) = $client->call;
    ok( !defined $err, 'no error' );
    is( $res->{status}, 200 );

    unlike( shows( $client->{options} ), qr/\Q$SECRET\E/, 'the options' );
    unlike( shows($st), qr/\Q$SECRET\E/, 'the station' );
    ok( !reaches_station( $client->{options}{feature} ), 'the activation entry reaches no Station' );
    $st->close;
    Voxgig::Station->reset;
};

subtest 'the caller\'s own key does not ride the activation entry' => sub {
    Voxgig::Station->reset;
    delete local $ENV{TASKPAD_APIKEY};
    my $st     = Voxgig::Station->open( { config => undef } );
    my $client = $st->adopt( 'ExposureSDK', { apikey => $SECRET } );
    $client->call;

    unlike( shows( $client->{options} ), qr/\Q$SECRET\E/, 'the options' );
    unlike( shows($st), qr/\Q$SECRET\E/, 'the station' );
    $st->close;
    Voxgig::Station->reset;
};

subtest 'inverted binding: the activation entry holds neither' => sub {
    Voxgig::Station->reset;
    my $st      = Voxgig::Station->open( { config => undef } );
    my $options = $st->options( { apikey => $SECRET } );

    is( $options->{apikey}, $SECRET, 'the SDK still gets the key it is given' );
    unlike( shows( $options->{feature}{station} ), qr/\Q$SECRET\E/, 'the entry' );
    ok( !reaches_station($options), 'the options reach no Station' );
    $st->close;
    Voxgig::Station->reset;
};

done_testing;
