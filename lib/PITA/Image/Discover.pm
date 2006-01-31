package PITA::Image::Discover;

use strict;
use base 'PITA::Image::Task';
use PITA::XML    ();
use Params::Util '_ARRAY';
use PITA::Scheme::Perl::Discovery ();

use vars qw{$VERSION};
BEGIN {
	$VERSION = '0.15';
}

sub new {
	my $class = shift;
	my $self  = bless { @_ }, $class;

	unless ( $self->scheme ) {
		Carp::croak("Missing option 'task.scheme' in image.conf");
	}
	unless ( $self->path ) {
		Carp::croak("Missing options 'task.path' in image.conf");
	}
	unless ( _ARRAY($self->platforms) ) {
		Carp::croak("Did not provide platforms array to Discover->new");
	}

	# Create a discovery object for each platform
	my @discoveries = ();
	foreach my $platform ( @{$self->platforms} ) {
		push @discoveries, PITA::Scheme::Perl::Discovery->new(
			scheme => $self->scheme,
			path   => $self->path,
			);
	}
	$self->{discoveries} = \@discoveries;

	$self;
}

sub scheme {
	$_[0]->{scheme};	
}

sub path {
	$_[0]->{path};
}

sub platforms {
	$_[0]->{platforms};
}

sub discoveries {
	$_[0]->{discoveries};
}





#####################################################################
# Run the discovery process

sub run {
	my $self = shift;

	# Create a Guest to hold the platforms.
	### Although we might not be running in the Local driver,
	### WE can't tell the difference, so we might as well be.
	### The driver will correct it later if it's wrong.
	my $guest = PITA::XML::Guest->new(
		driver => 'Local',
		params => {},
		);

	# Run the discovery on each platform
	foreach my $discovery ( @{$self->discoveries} ) {
		$discovery->delegate;
		if ( $discovery->platform ) {
			$guest->add_platform( $discovery->platform );
		} else {
			my $scheme = $self->scheme;
			my $path   = $self->path;
			Carp::croak("Error finding platform $scheme at $path");
		}
	}

	# Looks good, save
	$self->{result} = $guest;

	1;
}

sub result {
	$_[0]->{result};
}

1;