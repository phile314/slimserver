package Slim::Utils::Prefs::Base;

# $Id$

# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

=head1 NAME

Slim::Utils::Prefs::Base

=head1 DESCRIPTION

Base class for preference objects implementing methods which can be used on global and client preferences.

=head1 METHODS

=cut

use strict;

use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);
use Storable;

use Slim::Utils::Log;

my $optimiseAccessors = 1;

my $log = logger('prefs');

=head2 get( $prefname )

Returns the current value of preference $prefname.

(A preference value may also be accessed using $prefname as an accessor method.)

On SLIM_SERVICE, this pulls the value from the database if it doesn't already exist.

=cut

*get = main::SLIM_SERVICE ? \&get_SN : \&get_SC;

sub get_SC {
	$_[0]->{prefs}->{ $_[1] };
}

sub get_SN {
	my ( $class, $key ) = ( shift, shift );
	
	my $value = $class->{prefs}->{ $key };
	
	if ( main::SLIM_SERVICE ) {
		# Callers can force retrieval from the database
		my $force = shift;
	
		if ( !defined $value || $force ) {
		
			if ( $class->{clientid} ) {
				
				# Prepend namespace to key if it's not 'server'
				my $nskey = $key;
				if ( $class->namespace ne 'server' ) {
					my $ns = $class->namespace;
					$ns =~ s/\./_/g;
					$nskey = $ns . '_' . $key;
				}
				
				$value = $class->getFromDB($nskey);

				$class->{prefs}->{ $key } = $value;
			}
		}
		
		# Special handling for disabledirsets when there is only one disabled item
		if ( $key eq 'disabledirsets' && !ref $value ) {
			$value = [ $value ];
		}
		
		# More special handling for alarm prefs, ugh
		elsif ( $key =~ /^alarm/ && !ref $value ) {
			if ( $key !~ /alarmfadeseconds|alarmsEnabled/ ) {
				$value = [ $value ];
			}
		}
		
		if ( wantarray && ref $value eq 'ARRAY' ) {
			return @{$value};
		}
	}
	
	return $value;
}

=head2 getFromDB( $prefname )

SLIM_SERVICE only. Pulls a pref from the database.

=cut

sub getFromDB {
	my ( $class, $key ) = ( shift, shift );
	
	my $client = Slim::Player::Client::getClient( $class->{clientid} ) || return;
	
	# First search the player pref table
	my @prefs = SDI::Service::Model::Pref->search( {
		player => $client->playerData,
		name   => $key,
	} );
	
	my $count = scalar @prefs;

	if ( !$count ) {
		# If not found in player prefs, search user prefs
		@prefs = SDI::Service::Model::UserPref->search( {
			user => $client->playerData->userid,
			name => $key
		} );
		
		$count = scalar @prefs;
	}
	
	my $value;
	
	if ( $count == 1 ) {
		# scalar pref or JSON pref
		$value = $prefs[0]->value;
		
		if ( !defined $value ) {
			# NULL in DB is indicates empty string
			$value = '';
		}
			
		if ( $value =~ s/^json:// ) {
			$value = eval { from_json($value) };
			if ( $@ ) {
				$log->error( $client->id . " Bad JSON pref $key: $@" );
				$value = '';
			}
		}
	}
	elsif ( $count > 1 )  {
		# array pref
		$value = [];
		for my $pref ( @prefs ) {
			$value->[ $pref->idx ] = $pref->value;
		}
	}
	else {
		# nothing found
	}

	if ( $log->is_debug ) {
		$log->debug( sprintf( 
			"getFromDB: retrieved client pref %s-%s = %s",
			$client->id, $key, (defined($value) ? $value : 'undef')
		) );
	}
	
	return $value;
}

=head2 exists( $prefname )

Returns whether preference $prefname exists.

=cut

sub exists {
	exists shift->{'prefs'}->{ $_[0] };
}

=head2 validate( $pref, $new )

Validates new value for a preference.

=cut

sub validate {
	my $class = shift;
	my $pref  = shift;
	my $new   = shift;

	my $old   = $class->{'prefs'}->{ $pref };
	my $root  = $class->_root;
	my $validator = $root->{'validators'}->{ $pref };

	return $validator ? $validator->($pref, $new, $root->{'validparam'}->{ $pref }, $old, $class->_obj) : 1;
}

=head2 set( $prefname, $value )

Sets preference $prefname to $value.

If a validator is set for this $prefname this is checked first.  If an on change callback is set this is called
after setting the preference.

NB preferences only store scalar values.  Hashes or Arrays should be stored as references.

(A preference may also be set $prefname as an accessor method.)

=cut

sub set {
	my $class = shift;
	my $pref  = shift;
	my $new   = shift;

	my $old   = $class->{'prefs'}->{ $pref };

	my $root  = $class->_root;
	my $change = $root->{'onchange'}->{ $pref };
	my $readonly  = $root->{'readonly'};
	my $namespace = $root->{'namespace'};
	my $clientid  = $class->{'clientid'} || '';

	if (!ref $new && defined $new && defined $old && $new eq $old) {
		# suppress set when scalar and no change
		return wantarray ? ($new, 1) : $new;
	}

	my $valid = $class->validate($pref, $new);

	if ($readonly) {

		logBacktrace(sprintf "attempt to set %s:%s:%s while namespace is readonly", $namespace, $clientid, $pref);

		return wantarray ? ($old, 0) : $old;
	}

	if ( $valid && ( main::SLIM_SERVICE || $pref !~ /^_/ ) ) {

		if ( $log->is_debug ) {
			$log->debug(
				sprintf(
					"setting %s:%s:%s to %s",
					$namespace, $clientid, $pref, defined $new ? Data::Dump::dump($new) : 'undef'
				)
			);
		}
		
		if ( main::SLIM_SERVICE ) {
			# If old pref was an array but new is not, force it to stay an array
			if ( ref $old eq 'ARRAY' && !ref $new ) {
				$new = [ $new ];
			}
		}

		$class->{'prefs'}->{ $pref } = $new;
		
		if ( !main::SLIM_SERVICE ) { # SN's timestamps are stored automatically
			$class->{'prefs'}->{ '_ts_' . $pref } = time();
		}

		$root->save;
		
		my $client = Slim::Player::Client::getClient($clientid);
		
		if ( !defined $old || !defined $new || $old ne $new || ref $new ) {
			
			if ( main::SLIM_SERVICE && blessed($client) ) {
				# Skip param lets routines like initPersistedPrefs avoid writing right back to the db
				my $skip = shift || 0;

				if ( !$skip ) {
					# Save the pref to the db
					
					my $nspref = $pref;
					if ( $class->namespace ne 'server' ) {
						my $ns = $class->namespace;
						$ns =~ s/\./_/g;
						$nspref = $ns . '_' . $pref;
					}
					
					if ( ref $new eq 'ARRAY' ) {
						SDI::Service::Model::Pref->quick_update_array( $client->playerData, $nspref, $new );
					}
					elsif ( ref $new eq 'HASH' ) {
						SDI::Service::Model::Pref->quick_update( $client->playerData, $nspref, 'json:' . to_json( $new ) );
					}
					else {
						SDI::Service::Model::Pref->quick_update( $client->playerData, $nspref, $new );
					}
				}
			}

			for my $func ( @{$change} ) {
				if ( $log->is_debug ) {
					$log->debug('executing on change function ' . Slim::Utils::PerlRunTime::realNameForCodeRef($func) );
				}
				
				$func->($pref, $new, $class->_obj);
			}
		}

		Slim::Control::Request::notifyFromArray(
			$clientid ? $client : undef,
			['prefset', $namespace, $pref, $new]
		);

		return wantarray ? ($new, 1) : $new;

	} else {

		if ( $log->is_warn ) {
			$log->warn(
				sprintf(
					"attempting to set %s:%s:%s to %s - invalid value",
					$namespace, $clientid, $pref, defined $new ? Data::Dump::dump($new) : 'undef'
				)
			);
		}

		return wantarray ? ($old, 0) : $old;
	}
}

sub _obj {}

=head2 init( Hash )

Initialises any preference values which currently do not exist.

Hash is of the format: { 'prefname' => 'initial value' }

=cut

sub init {
	my $class = shift;
	my $hash  = shift;

	my $changed = 0;

	for my $pref (keys %$hash) {

		if (!exists $class->{'prefs'}->{ $pref }) {

			my $value;

			if (ref $hash->{ $pref } eq 'CODE') {

				$value = $hash->{ $pref }->( $class->_obj );

			} elsif (ref $hash->{ $pref }) {

				# dclone data structures to ensure each client gets its own copy
				$value = Storable::dclone($hash->{ $pref });

			} else {

				$value = $hash->{ $pref };
			}

			if ( $log->is_info ) {
				$log->info(
					"init " . $class->_root->{'namespace'} . ":" 
					. ($class->{'clientid'} || '') . ":" . $pref 
					. " to " . (defined $value ? Data::Dump::dump($value) : 'undef')
				);
			}

			$class->{'prefs'}->{ $pref } = $value;
			
			if ( !main::SLIM_SERVICE ) { # SN's timestamps are stored automatically
				$class->{'prefs'}->{ '_ts_' . $pref } = time();
			}

			$changed = 1;
		}
	}

	$class->_root->save if $changed;
}

=head2 remove ( list )

Removes (deletes) all preferences in the list.

=cut

sub remove {
	my $class = shift;

	while (my $pref  = shift) {

		if ( $log->is_info ) {
			$log->info(
				"removing " . $class->_root->{'namespace'} . ":" . ($class->{'clientid'} || '') . ":" . $pref
			);
		}

		delete $class->{'prefs'}->{ $pref };
		
		if ( !main::SLIM_SERVICE ) {
			delete $class->{'prefs'}->{ '_ts_' . $pref };
		}
		
		if ( main::SLIM_SERVICE && $class->{clientid} ) {
			# Remove the pref from the database
			my $client = Slim::Player::Client::getClient( $class->{clientid} );
			SDI::Service::Model::Pref->sql_clear_array->execute(
				$client->playerData->id,
				$pref,
			);
		}
	}

	$class->_root->save;
}

=head2 all ( )

Returns all preferences at this level (all global prefernces in a namespace, or all client preferences in a namespace).

=cut

sub all {
	my $class = shift;

	my %prefs = %{$class->{'prefs'}};

	for my $pref (keys %prefs) {
		delete $prefs{$pref} if $pref =~ /^\_/;
	}

	return \%prefs;
}

=head2 clear ( )

Clears all preferences. SLIM_SERVICE only.

=cut

sub clear {
	my $class = shift;
	
	for my $pref ( keys %{ $class->{prefs} } ) {
		delete $class->{prefs}->{$pref};
	}
}

=head2 loadHash ( $prefs )

Load all prefs at once from a hashref. SLIM_SERVICE only.

=cut

sub loadHash {
	my ( $class, $hash ) = @_;
	
	while ( my ($pref, $value) = each %{$hash} ) {
		$class->{prefs}->{ $pref } = $value;
	}
}

=head2 hasValidator( $pref )

Returns whether preference $pref has a validator function defined.

=cut

sub hasValidator {
	my $class = shift;
	my $pref  = shift;

	return $class->_root->{'validators'}->{ $pref }  ? 1 : 0;
}

=head2 namespace( )

Returns namespace for this preference object.

=cut

sub namespace {
	my $class = shift;

	return $class->_root->{'namespace'};
}

=head2 timestamp( $pref )

Returns last-modified timestamp for this preference

=cut

sub timestamp {
	my ( $class, $pref, $wipe ) = @_;
	
	if ( main::SLIM_SERVICE ) {
		return 0;
	}
	
	if ( $wipe ) {
		$class->{'prefs'}->{ '_ts_' . $pref } = -1;
	}
	
	return $class->{'prefs'}->{ '_ts_' . $pref } ||= 0;
}

sub AUTOLOAD {
	my $class = shift;

	my $package = blessed($class);

	our $AUTOLOAD;

	my ($pref) = $AUTOLOAD =~ /$package\:\:(.*)/;

	return if (!$pref || $pref eq 'DESTROY');

	if ($optimiseAccessors) {

		if ( $log->is_debug ) {
			$log->debug(
				  "creating accessor for " 
				. $class->_root->{'namespace'} . ":" 
				. ($class->{'clientid'} || '') . ":" . $pref
			);
		}

		no strict 'refs';
		*{ $AUTOLOAD } = sub { @_ == 1 ? $_[0]->{'prefs'}->{ $pref } : $_[0]->set($pref, $_[1]) };
	}

	return @_ == 0 ? $class->{'prefs'}->{ $pref } : $class->set($pref, shift);
}

=head2 SEE ALSO

L<Slim::Utils::Prefs::Base>
L<Slim::Utils::Prefs::Namespace>
L<Slim::Utils::Prefs::Client>
L<Slim::Utils::Preds::OldPrefs>

=cut

1;
