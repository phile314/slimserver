package Slim::Plugin::Extensions::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::OSDetect;

use Digest::MD5;

my $prefs = preferences('plugin.extensions');
my $log   = logger('plugin.extensions');

my $os   = Slim::Utils::OSDetect->getOS();
my $rand = Digest::MD5->new->add( 'ExtensionDownloader', preferences('server')->get('securitySecret'), time )->hexdigest;

sub name {
	# we override the main server plugin setup page
	return Slim::Web::HTTP::CSRF->protectName('SETUP_PLUGINS');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Extensions/settings/basic.html');
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	# Simplistic anti CSRF protection in case the main server protection is off
	if (($params->{'saveSettings'} || $params->{'restart'}) && (!$params->{'rand'} || $params->{'rand'} ne $rand)) {

		$log->error("attempt to set params with band random number - ignoring");

		delete $params->{'saveSettings'};
		delete $params->{'restart'};
	}

	if ($params->{'saveSettings'}) {

		# handle changes to auto mode

		my $auto = $params->{'auto'} ? 1 : 0;
		$prefs->set('auto', $auto) if $auto != $prefs->get('auto');

		# handle changes to repos

		my @new = grep { $_ =~ /^http:\/\/.*\.xml/ } (ref $params->{'repos'} eq 'ARRAY' ? @{$params->{'repos'}} : $params->{'repos'});

		my %current = map { $_ => 1 } @{ $prefs->get('repos') || [] };
		my %new     = map { $_ => 1 } @new;
		my $changed;

		for my $repo (keys %new) {
			if (!$current{$repo}) {
				Slim::Plugin::Extensions::Plugin->addRepo({ repo => $repo });
				$changed = 1;
			}
		}
		
		for my $repo (keys %current) {
			if (!$new{$repo}) {
				Slim::Plugin::Extensions::Plugin->removeRepo({ repo => $repo });
				$changed = 1;
			}
		}

		$prefs->set('repos', \@new) if $changed;

		if ($params->{'otherrepo'} && !$prefs->get('otherrepo')) {

			Slim::Plugin::Extensions::Plugin->addRepo({ other => 1 });
			$prefs->set('otherrepo', 1);

		} elsif (!$params->{'otherrepo'} && $prefs->get('otherrepo')) {

			Slim::Plugin::Extensions::Plugin->removeRepo({ other => 1 });
			$prefs->set('otherrepo', 0);
		}

		# set policy for which plugins are installed/uninstalled etc

		my $plugin = $prefs->get('plugin');
		undef $changed;

		for my $param (keys %$params) {

			if ($param =~ /^manual:(.*)/) {
				$params->{$1} ? Slim::Utils::PluginManager->enablePlugin($1) : Slim::Utils::PluginManager->disablePlugin($1);
			}

			if ($param =~ /^install:(.*)/) {
				if ($params->{$1} && !$plugin->{$1}) {
					$plugin->{$1} = 1;
					$changed = 1;
				} elsif (!$params->{$1} && $plugin->{$1}) {
					delete $plugin->{$1};
					$changed = 1;
				}
			}
		}
		
		$prefs->set('plugin', $plugin) if $changed;
	}

	# get plugin info from defined repos
	my $repos = Slim::Plugin::Extensions::Plugin->repos;

	my $data = { remaining => scalar keys %$repos, results => {}, errors => {} };

	for my $repo (keys %$repos) {
		Slim::Plugin::Extensions::Plugin::getExtensions({
			'name'   => $repo, 
			'type'   => 'plugin', 
			'target' => Slim::Utils::OSDetect::OS(),
			'version'=> $::VERSION, 
			'lang'   => $Slim::Utils::Strings::currentLang,
			'details'=> 1,
			'cb'     => \&_getReposCB,
			'pt'     => [ $class, $client, $params, $callback, \@args, $data, $repos->{$repo} ],
			'onError'=> sub { $data->{'errors'}->{ $_[0] } = $_[1] },
		});
	}

	if (!keys %$repos) {
		_getReposCB( $class, $client, $params, $callback, \@args, $data, undef, {}, {} );
	}
}

sub _getReposCB {
	my ($class, $client, $params, $callback, $args, $data, $weight, $res, $info) = @_;

	if (scalar @$res) {

		$data->{'results'}->{ $info->{'name'} } = {
			'title'   => $info->{'title'},
			'entries' => $res,
			'weight'  => $weight,
		};
	}

	if ( --$data->{'remaining'} <= 0 ) {

		$callback->($client, $params, $class->_addInfo($client, $params, $data), @$args);
	}
}

sub _addInfo {
	my ($class, $client, $params, $data) = @_;

	my $plugins = Slim::Utils::PluginManager->allPlugins;
	my $states  = preferences('plugin.state');

	my $hide = {};
	my $current = {};

	# create entries for built in plugins and those already installed
	my @active;
	my @inactive;
	my @updates;

	for my $plugin (keys %$plugins) {

		my $entry = $plugins->{$plugin};
		my $state = $states->get($plugin);

		my $entry = {
			name    => $plugin,
			title   => Slim::Utils::Strings::getString($entry->{'name'}),
			desc    => Slim::Utils::Strings::getString($entry->{'description'}),
			error   => Slim::Utils::PluginManager->getErrorString($plugin),
			creator => $entry->{'creator'},
			email   => $entry->{'email'},
			version => $entry->{'version'},
			settings=> Slim::Utils::PluginManager->isEnabled($entry->{'module'}) ? $entry->{'optionsURL'} : undef,
			manual  => $entry->{'basedir'} !~ /InstalledPlugins/ ? 1 : 0,
			enforce => $entry->{'enforce'},
		};

		if ($state =~ /enabled/) {

			push @active, $entry;

			if (!$entry->{'manual'}) {
				$current->{ $plugin } = $entry->{'version'};
			}

		} elsif ($state =~ /disabled/) {

			push @inactive, $entry;
		}

		$hide->{$plugin} = 1;
	}

	my @results = sort { $a->{'weight'} !=  $b->{'weight'} ?
						 $a->{'weight'} <=> $b->{'weight'} : 
						 $a->{'title'} cmp $b->{'title'} } values %{$data->{'results'}};

	my @res;

	for my $res (@results) {
		push @res, @{$res->{'entries'}};
	}

	# find update actions and handle

	my $actions = Slim::Plugin::Extensions::Plugin::findUpdates(\@res, $current, $prefs->get('plugin'), 'info');

	for my $plugin (keys %$actions) {

		my $entry = $actions->{$plugin};

		if ($entry->{'action'} eq 'install' && $entry->{'url'} && $entry->{'sha'}) {

			if (!defined $current->{$plugin} || $prefs->get('auto') || ($params->{'saveSettings'} && $params->{"update:$plugin"}) ) {

				# install now if not installed, in auto mode or update has been explicitly selected
				main::INFOLOG && $log->info("installing $plugin from $entry->{url}");

				Slim::Utils::PluginDownloader->install({ name => $plugin, url => $entry->{'url'}, sha => $entry->{'sha'} });

			} else {

				# add to update list
				push @updates, $entry->{'info'};
			}
							 
		} elsif ($entry->{'action'} eq 'uninstall') {

			main::INFOLOG && $log->info("uninstalling $plugin");

			Slim::Utils::PluginDownloader->uninstall($plugin);
		}
	}

	Slim::Utils::PluginManager->message(undef);

	# prune out duplicate entries, favour favour higher version numbers
	
	# pass 1 - find the higher version numbers
	my $max = {};

	for my $repo (@results) {
		for my $entry (@{$repo->{'entries'}}) {
			my $name = $entry->{'name'};
			if (!defined $max->{$name} || Slim::Utils::Versions->compareVersions($entry->{'version'}, $max->{$name}) > 0) {
				$max->{$name} = $entry->{'version'};
			}
		}
	}

	# pass 2 - prune out lower versions or entries which are hidden as they are shown in enabled plugins
	for my $repo (@results) {
		my $i = 0;
		while (my $entry = $repo->{'entries'}->[$i]) {
			if ($hide->{$entry->{'name'}} || $max->{$entry->{'name'}} ne $entry->{'version'}) {
				splice @{$repo->{'entries'}}, $i, 1;
				next;
			}
			$i++;
		}
	}

	my @repos = ( @{$prefs->get('repos')}, '' );

	$params->{'updates'}  = \@updates;
	$params->{'active'}   = \@active;
	$params->{'inactive'} = \@inactive;
	$params->{'avail'}    = \@results;
	$params->{'repos'}    = \@repos;
	$params->{'otherrepo'}= $prefs->get('otherrepo');
	$params->{'auto'}     = $prefs->get('auto');
	$params->{'rand'}     = $rand;

	my $needsRestart = Slim::Utils::PluginManager->needsRestart || Slim::Utils::PluginDownloader->downloading;

	$params->{'warning'} = $needsRestart ? Slim::Utils::Strings::string("PLUGIN_EXTENSIONS_RESTART_MSG") : '';

	# show a link/button to restart SC if this is supported by this platform
	if ($needsRestart) {
		$params = Slim::Web::Settings::Server::Plugins->getRestartMessage($params, Slim::Utils::Strings::string("PLUGIN_EXTENSIONS_RESTART_MSG"));
	}

	$params = Slim::Web::Settings::Server::Plugins->restartServer($params, $needsRestart);

	for my $repo (keys %{$data->{'errors'}}) {
		$params->{'warning'} .= Slim::Utils::Strings::string("PLUGIN_EXTENSIONS_REPO_ERROR") . " $repo - $data->{errors}->{$repo}<p/>";
	}

	return $class->SUPER::handler($client, $params);
}


1;
