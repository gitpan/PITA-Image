package PITA::Image::Manager;

=pod

=head1 NAME

PITA::Image::Manager - PITA Guest Manager for inside system images

=head1 SYNOPSIS

A typical startup script

  #!/usr/bin/perl
  
  use strict;
  use IPC::Run3;
  use PITA::Image::Manager;
  
  # Wrap the main actions in an eval to catch errors
  eval {
      # Configure the image manager
      my $manager = PITA::Image::Manager->new(
          injector => '/mnt/hbd1',
          workarea => '/tmp',
          );
      $manager->add_context(
          scheme => 'perl5',
          path   => '', # Default system Perl
          );
      $manager->add_context(
          scheme => 'perl5',
          path   => '/opt/perl5-6-1/bin/perl'
          );
  
      # Run the tasks
      $manager->run;
  
      # Report the results
      $manager->report;
  };
  
  # Shut down the computer on completion or failure
  run3( [ 'shutdown', '-h', '0' ], \undef );
  
  exit(0);

And a typical configuration image.conf

  class=PITA::Image::Manager
  version=0.10
  support=http://10.0.2.2/
  
  [ task ]
  task=Test
  scheme=perl5.make
  path=/usr/bin/perl
  request=request-512311.conf

=head1 DESCRIPTION

While most of the PITA system exists outside the guest images and
tries to have as little interaction with them as possible, there is one
part that needs to be run from inside it.

The C<PITA::Image::Manager> class lives inside the image and has the
responsibility of accepting the injector directory at startup, executing
the requested tasks, and then shutting down the (virtual) computer.

=head1 Setting up a Testing Image

Each image that will be set up will require a bit of customization,
as the entire point of this type of testing is that every environment
is different.

However, by keeping most of the functionality in the
C<PITA::Image::Manager> and L<PITA::Scheme> classes, all you should need
to do is to arrange for a relatively simple Perl script to be launched,
that feeds some initial configuration to to a new
C<PITA::Image::Manager> object.

And it should do the rest.

=head1 METHODS

=cut

use 5.005;
use strict;
use Carp                  ();
use File::Spec            ();
use File::Which           ();
use Config::Tiny          ();
use Params::Util          ':ALL';
use LWP::UserAgent        ();
use HTTP::Request::Common 'GET', 'PUT';

use vars qw{$VERSION $NOSERVER};
BEGIN {
	$VERSION = '0.11';
}





#####################################################################
# Constructor and Accessors

=pod

=head2 new

  my $manager = PITA::Image::Manager->new(
  	injector => '/mnt/hdb1',
  	workarea => '/tmp',
  	);

The C<new> creates a new image manager. It takes two named parameters.

=over 4

=item injector

The required C<injector> param is a platform-specific path to the
root of the already-mounted F</dev/hdb1> partition (or the equivalent
on your operating system). The image configuration is expected to
exist at F<image.conf> within this directory.

=item workarea

The optional C<workarea> param provides a directory writable by the
current user that can be used to hold any files and do any processing
in during the running of the image tasks.

If you do not provide a value, C<File::Temp::tempdir()> will be used
to find a default usable directory.

=back

Returns a new C<PITA::Image::Manager> object, or dies on error.

=cut

sub new {
	my $class = shift;
	my $self  = bless { @_ }, $class;

	# Check some params
	unless ( $self->injector ) {
		Carp::croak("Manager 'injector' was not provided");
	}
	unless ( -d $self->injector ) {
		Carp::croak("Manager 'injector' does not exist");
	}
	unless ( -r $self->injector ) {
		Carp::croak("Manager 'injector' cannot be read, insufficient permissions");
	}

	# Find a temporary directory to use for the testing
	unless ( $self->workarea ) {
		$self->{workarea} = File::Temp::tempdir();
	}
	unless ( $self->workarea ) {
		Carp::croak("Manager 'workarea' not provided and automatic detection failed");
	}
	unless ( -d $self->workarea ) {
		Carp::croak("Manager 'workarea' directory does not exist");
	}
	unless ( -r $self->workarea and -w _ ) {
		Carp::croak("Manager 'workarea' insufficient permissions");
	}

	# Find the main config file
	unless ( $self->image_conf ) {
		$self->{image_conf} = File::Spec->catfile(
			$self->injector, 'image.conf',
			);
	}
	unless ( $self->image_conf ) {
		Carp::croak("Did not get an image.conf location");
	}
	unless ( -f $self->image_conf ) {
		Carp::croak("Failed to find image.conf in the injector");
	}
	unless ( -r $self->image_conf ) {
		Carp::croak("No permissions to read scheme.conf");
	}

	# Load the main config file
	unless ( $self->config ) {
		$self->{config} = Config::Tiny->read( $self->image_conf );
	}
	unless ( _INSTANCE($self->config, 'Config::Tiny') ) {
		Carp::croak("Failed to load scheme.conf config file");
	}

	# Verify that we can use this config file
	my $config = $self->config->{_};
	unless ( $config->{class} and $config->{class} eq $class ) {
		Carp::croak("Config file is incompatible with PITA::Image::Manager");
	}
	unless ( $config->{version} and $config->{version} eq $VERSION ) {
		Carp::croak("Config file is incompatible with this version of PITA::Image::Manager");
	}

	# If provided, apply the optional lib path so some libraries
	# can be upgraded in a pince without upgrading all the images
	if ( $config->{perl5lib} ) {
		$self->{perl5lib} = File::Spec->catdir(
			$self->injector, split( /\//, $config->{perl5lib} ),
			);
		unless ( -d $self->perl5lib ) {
			Carp::croak("Injector lib directory does not exist");
		}
		unless ( -r $self->perl5lib ) {
			Carp::croak("Injector lib directory has no read permissions");
		}
		require lib;
		lib->import( $self->perl5lib );
	}

	# Check the support server
	unless ( $self->server_uri ) {
		$self->{server_uri} = URI->new($config->{server_uri});
	}
	unless ( $self->server_uri ) {
		Carp::croak("Missing 'server_uri' param in image.conf");
	}
	unless ( _INSTANCE($self->server_uri, 'URI::http') ) {
		Carp::croak("The 'server_uri' is not a HTTP(S) URI");
	}
	unless ( $NOSERVER ) {
		my $response = LWP::UserAgent->new->request( GET $self->server_uri );
		unless ( $response and $response->is_success ) {
			Carp::croak("Failed to contact SupportServer at $config->{server_uri}");
		}
	}

	### Task-Specific Setup.
	### Move to iterative code later.
	$self->{tasks} = [];

	# We expect a task at [ task ]
	unless ( $self->config->{task} ) {
		Carp::croak("Missing [task] section in image.conf");
	}

	# Resolve the specific schema class for this test run
	my $scheme = $self->config->{task}->{scheme};
	unless ( $scheme ) {
		Carp::croak("Missing option 'task.scheme' in image.conf");
	}
	my $driver = join( '::', 'PITA', 'Scheme', map { ucfirst $_ } split /\./, lc($scheme || '') );
	unless ( _CLASS($driver) ) {
		Carp::croak("Invalid scheme '$scheme' for task.scheme in in image.conf");
	}

	# Load the scheme class
	eval "require $driver;";
	if ( $@ =~ /^Can\'t locate PITA/ ) {
		Carp::croak("Scheme '$scheme' is unsupported on this Guest");
	} elsif ( $@ ) {
		Carp::croak("Error loading scheme '$scheme' driver $driver: $@");
	}

	# Did we get a path
	my $path = $self->config->{task}->{path};
	unless ( defined $path ) {
		Carp::croak("Missing option task.path in image.conf");
	}

	# Did we get a config file
	my $config_file = $self->config->{task}->{config};
	unless ( $config_file ) {
		Carp::croak("Missing option task.config in image.conf");
	}

	# Did we get a job_id?
	my $job_id = $self->config->{task}->{job_id};
	unless ( $job_id and _POSINT($job_id) ) {
		Carp::croak("Missing option task.job_id in image.conf");
	}

	# Did we get a request?
	# Create the task object from it
	my $task = $driver->new(
		injector    => $self->injector,
		workarea    => $self->workarea,
		scheme      => $scheme,
		path        => $path,
		request_xml => $config_file,
		request_id  => $job_id,
		);
	$self->add_task( $task );

	$self;
}

sub injector {
	$_[0]->{injector};	
}

sub workarea {
	$_[0]->{workarea};
}

sub image_conf {
	$_[0]->{image_conf};
}

sub config {
	$_[0]->{config};
}

sub perl5lib {
	$_[0]->{perl5lib};
}

sub server_uri {
	$_[0]->{server_uri};
}





#####################################################################
# Main Methods

sub add_task {
	my $self = shift;
	my $task = _INSTANCE(shift, 'PITA::Scheme')
		or die("Passed bad param to add_task");
	push @{$self->{tasks}}, $task;
	1;
}

sub tasks {
	@{$_[0]->{tasks}};
}

sub run {
	my $self = shift;

	# Test each scheme
	foreach my $task ( $self->tasks ) {
		if ( $task->isa('PITA::Scheme') ) {
			# Run the test
			$self->run_scheme( $task );

		} else {
			Carp::croak("Cannot run unknown task");
		}
	}

	1;
}

sub run_scheme {
	my ($self, $scheme) = @_;
	$scheme->prepare_all;
	$scheme->execute_all;
}

sub report {
	my $self = shift;

	# Test each scheme
	foreach my $task ( $self->tasks ) {
		if ( $task->isa('PITA::Scheme') ) {
			# Run the test
			$self->report_scheme( $task );

		} else {
			Carp::croak("Cannot run unknown task");
		}
	}

	1;
}

sub report_scheme {
	my $self    = shift;
	my $scheme  = shift;
	my $agent   = LWP::UserAgent->new;
	my $request = $self->report_scheme_request( $scheme );
	unless ( _INSTANCE($request, 'HTTP::Request') ) {
		Carp::croak("Did not generate proper report HTTP::Request");
	}
	unless ( $NOSERVER ) {
		my $response = $agent->request( $request );
		unless ( $response and $response->is_success ) {
			Carp::croak("Failed to send result report to server");
		}
	}

	1;
}

sub report_scheme_request {
	my ($self, $scheme) = @_;	
	unless ( $scheme->report ) {
		Carp::croak("No Report created to PUT");
	}

	# Serialize the data for sending
	my $xml = '';
	$scheme->report->write( \$xml );
	unless ( length($xml) ) {
		Carp::croak("Failed to serialize report");
	}

	# Send the file
	PUT $self->report_scheme_uri( $scheme ),
		content_type   => 'application/xml',
		content_length => length($xml),
		content        => $xml;
}

# The location to put to
sub report_scheme_uri {
	my ($self, $scheme) = @_;
	my $uri  = $self->server_uri;
	my $job  = $scheme->request_id;
	my $path = File::Spec->catfile( $uri->path || '/', $job );
	$uri->path( $path );
	$uri;
}

1;

=pod

=head1 SUPPORT

Bugs should be reported via the CPAN bug tracker at

L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=PITA-Image>

For other issues, contact the author.

=head1 AUTHOR

Adam Kennedy E<lt>cpan@ali.asE<gt>, L<http://ali.as/>

=head1 SEE ALSO

The Perl Image Testing Architecture (L<http://ali.as/pita/>)

L<PITA>, L<PITA::XML>, L<PITA::Scheme>

=head1 COPYRIGHT

Copyright 2005 - 2006 Adam Kennedy. All rights reserved.

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.

=cut
