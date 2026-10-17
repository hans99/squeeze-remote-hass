package Plugins::Assistant::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::Assistant::API;
use Plugins::Assistant::Handlers;
use Plugins::Assistant::Images;

my $log = Slim::Utils::Log->addLogCategory(
	{
		'category'     => 'plugin.assistant',
		'defaultLevel' => 'ERROR',
		'description'  => 'PLUGIN_ASSISTANT',
	}
);

my $prefs = preferences('plugin.assistant');

my $menuItems = [];
my $running = 0;
my $initialized = 0;
my %domains = map { $_ => 1 } qw(light switch cover);

sub initPlugin {
	my $class = shift;

	$prefs->init({
		enabled => 0,
		connect => '',
		pass    => '',
	});

	if (main::WEBUI) {
		require Plugins::Assistant::Settings;
		Plugins::Assistant::Settings->new();
	}

	unless ($initialized) {
		$class->SUPER::initPlugin(
			feed   => \&handleFeed,
			tag    => 'assistant',
			menu   => 'apps',
			is_app => 1,
		);
		Plugins::Assistant::Images::register();
		$initialized = 1;
	}

	if ($prefs->get('enabled')) {
		$class->start();
	}
}

sub shutdownPlugin {
	my $class = shift;

	main::DEBUGLOG && $log->is_debug && $log->debug('shutdownPlugin');
	$class->stop();
	$class->removeHomePins();
	# OPMLBased/Base do not define shutdownPlugin — do not call SUPER
}

# Remove "Pin to home screen" entries (SqueezePlay / Material Skin server defaults)
sub removeHomePins {
	my $class = shift;

	my $jiveId = 'opmlassistant';
	eval {
		require Slim::Control::Jive;
		Slim::Control::Jive::deleteMenuItem($jiveId);
		foreach my $client (Slim::Player::Client::clients()) {
			Slim::Control::Jive::deleteMenuItem($jiveId, $client);
		}
		1;
	} or do {
		main::DEBUGLOG && $log->is_debug && $log->debug('Jive home pin cleanup skipped: ', $@ || '');
	};

	eval {
		my $msPrefs = preferences('plugin.material-skin');
		my $removed = 0;

		for my $key (qw(items pinned)) {
			my $raw = $msPrefs->get($key);
			next unless defined $raw && length $raw;

			my $list;
			eval { $list = decode_json($raw) };
			next unless ref $list eq 'ARRAY';

			my @kept = grep { !_isAssistantHomePin($_) } @$list;
			next if @kept == @$list;

			$msPrefs->set($key, encode_json(\@kept));
			$removed += @$list - @kept;
		}

		if ($removed) {
			$msPrefs->savenow();
			main::INFOLOG && $log->is_info && $log->info(
				"Removed $removed Assistant pin(s) from Material Skin home defaults"
			);

			eval {
				Slim::Control::Request::notifyFromArray(
					undef, ['material-skin', 'notification', 'internal', 'refresh-home']
				);
			};
		}
		1;
	} or do {
		main::DEBUGLOG && $log->is_debug && $log->debug('Material Skin pin cleanup skipped: ', $@ || '');
	};
}

sub _isAssistantHomePin {
	my ($item) = @_;
	return 0 unless $item && ref $item eq 'HASH';

	my $id = $item->{id} // '';
	return 1 if $id eq 'apps.assistant' || $id eq 'opmlassistant';

	if (ref $item->{command} eq 'ARRAY' && @{$item->{command}}) {
		return 1 if $item->{command}[0] eq 'assistant';
	}

	if (ref $item->{params} eq 'ARRAY') {
		return 1 if grep { $_ eq 'menu:assistant' } @{$item->{params}};
	}
	elsif (ref $item->{params} eq 'HASH') {
		return 1 if ($item->{params}{menu} // '') eq 'assistant';
	}

	return 0;
}

sub restart {
	my $class = shift;

	main::INFOLOG && $log->is_info && $log->info('Restarting Assistant');
	$class->stop();
	$class->start();
}

sub start {
	my $class = shift;

	unless ($prefs->get('connect') && $prefs->get('pass')) {
		$log->error('Cannot start: connect URL or access token not set');
		return;
	}

	if ($running) {
		$class->stop();
	}

	main::INFOLOG && $log->is_info && $log->info('Starting Assistant');
	$running = 1;
	$menuItems = [];

	Plugins::Assistant::API->init({
		onReady      => \&_onHomeAssistantReady,
		onAuthFailed => \&_onHomeAssistantAuthFailed,
	});
}

sub stop {
	my $class = shift;

	main::INFOLOG && $log->is_info && $log->info('Stopping Assistant');

	$running = 0;
	$menuItems = [];

	Slim::Utils::Timers::killTimers(undef, \&_buildMenu);
	Plugins::Assistant::API->shutdown();
}

sub getDisplayName { 'PLUGIN_ASSISTANT' }

sub playerMenu {}

sub _onHomeAssistantReady {
	return unless $running;

	main::INFOLOG && $log->is_info && $log->info('Home Assistant ready, building menu');
	$menuItems = [];
	_buildMenu();
}

sub _onHomeAssistantAuthFailed {
	my ($message) = @_;
	$log->error('Stopping after auth failure: ', $message || '');
	$running = 0;
	$menuItems = [];
	Slim::Utils::Timers::killTimers(undef, \&_buildMenu);
}

sub _buildMenu {
	return unless $running;

	main::DEBUGLOG && $log->is_debug && $log->debug('Building area menu');

	Plugins::Assistant::API->getAreas(sub {
		my ($areas, $err) = @_;

		return unless $running;

		if ($err || !defined $areas) {
			$log->error('Failed to getAreas: ', $err || 'no data');
			Slim::Utils::Timers::killTimers(undef, \&_buildMenu);
			Slim::Utils::Timers::setTimer(undef, time() + 5, \&_buildMenu);
			return;
		}

		unless (ref $areas eq 'ARRAY') {
			$log->error('Invalid getAreas payload');
			return;
		}

		my @sortedAreas = sort {
			lc($a->{name} // '') cmp lc($b->{name} // '')
		} @$areas;

		my $pending = scalar @sortedAreas;
		my @built;
		my @allEntityIds;

		if ($pending == 0) {
			$menuItems = [];
			return;
		}

		foreach my $area (@sortedAreas) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Area ', JSON::XS->new->pretty->encode($area));

			Plugins::Assistant::API->getEntities(sub {
				my ($entities, $entityErr) = @_;

				return unless $running;

				$pending--;

				if (!$entityErr && ref $entities eq 'HASH') {
					my ($items, $subscriptions) = _entitiesForArea($entities);

					if (@$items) {
						push @built, {
							name   => $area->{name},
							image  => Plugins::Assistant::Images::imagePath($area->{picture}),
							areaId => $area->{area_id},
							items  => $items,
						};
						push @allEntityIds, @$subscriptions;
					}
				}
				elsif ($entityErr) {
					$log->error('Failed to getEntities for ', $area->{name}, ': ', $entityErr);
				}

				return if $pending > 0;

				# All areas processed: publish menu and one subscription
				@built = sort { lc($a->{name} // '') cmp lc($b->{name} // '') } @built;
				$menuItems = \@built;

				main::INFOLOG && $log->is_info && $log->info(
					'Menu ready: ', scalar(@built), ' areas, ', scalar(@allEntityIds), ' entities'
				);

				if (@allEntityIds) {
					my %seen;
					my @unique = grep { !$seen{$_}++ } @allEntityIds;
					Plugins::Assistant::API->subscribeEntities(\&AssistantEntity, @unique);
				}
			}, $area->{area_id});
		}
	});
}

sub _entitiesForArea {
	my ($decoded) = @_;

	my $jsEntities = $decoded->{referenced_entities} || [];
	if (ref $jsEntities ne 'ARRAY') {
		$jsEntities = [ keys %$jsEntities ] if ref $jsEntities eq 'HASH';
		$jsEntities = [] unless ref $jsEntities eq 'ARRAY';
	}

	my @entitySubscriptions;
	my $items = [];

	foreach my $entity (sort @$jsEntities) {
		my $dot = index($entity, '.');
		next if $dot < 1;
		my $domain = substr($entity, 0, $dot);
		main::DEBUGLOG && $log->is_debug && $log->debug('Domain: ', $domain, ' - Entity: ', $entity);
		next unless $domains{$domain};
		push @entitySubscriptions, $entity;
		my $item = {
			entity => $entity,
			domain => $domain,
			name   => $entity,
			type   => 'text',
		};
		Plugins::Assistant::Images::applyItemImage($item);
		push @$items, $item;
	}

	return ($items, \@entitySubscriptions);
}

sub AssistantAction {
	my ($client, $cb, $params, $args) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('AssistantAction start ', JSON::XS->new->pretty->encode($args));

	my $serviceFn = $Plugins::Assistant::Handlers::service{$args->{domain}};
	unless ($serviceFn) {
		$log->error('No service handler for domain: ', $args->{domain});
		$cb->();
		return;
	}

	my $service = $serviceFn->($args->{state});
	my $actionRequest = {
		domain  => $args->{domain},
		entity  => $args->{entity},
		service => $service,
	};

	Plugins::Assistant::API->serviceAction(sub {
		my ($result, $err) = @_;
		if ($err) {
			$log->error('AssistantAction failed: ', $err);
			return;
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('AssistantAction sent');
	}, $actionRequest);

	# OPML nextWindow=parent: return immediately; state arrives via subscription
	$cb->();
	return;
}

sub AssistantEntity {
	my ($entities, $err) = @_;

	if ($err) {
		$log->error('AssistantEntity error: ', $err);
		return;
	}

	return unless ref $entities eq 'HASH';
	main::DEBUGLOG && $log->is_debug && $log->debug('AssistantEntity update keys: ', join(',', keys %$entities));

	foreach my $key (qw(a c r)) {
		next unless exists $entities->{$key};
		my $handler = $Plugins::Assistant::Handlers::entities{$key};
		next unless ref($handler) eq 'CODE';

		my $updates = $handler->($entities);
		next unless $updates && ref $updates eq 'ARRAY';

		foreach my $entity (@$updates) {
			_applyEntityUpdate($entity);
		}
	}
}

sub _applyEntityUpdate {
	my ($entity) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug('Entity update ', JSON::XS->new->pretty->encode($entity));

	foreach my $menuItem (@$menuItems) {
		my $menuItemItems = $menuItem->{items} || [];
		foreach my $menuItemEntity (@$menuItemItems) {
			if ($menuItemEntity->{entity} eq $entity->{entity}) {
				if ($entity->{removed}) {
					$menuItemEntity->{name} //= $entity->{entity};
					$menuItemEntity->{state} = 'unavailable';
					$menuItemEntity->{entityPicture} = undef;
					$menuItemEntity->{entityIcon} = undef;
					$menuItemEntity->{type} = 'text';
					delete $menuItemEntity->{url};
					delete $menuItemEntity->{passthrough};
					Plugins::Assistant::Images::applyItemImage($menuItemEntity);
					return;
				}

				$menuItemEntity->{name} = $entity->{name} if defined $entity->{name};
				# Allow HA to clear icon (undef) as well as set it
				$menuItemEntity->{entityIcon} = $entity->{icon} if exists $entity->{icon};
				$menuItemEntity->{state} = $entity->{state} if defined $entity->{state};

				if (exists $entity->{entity_picture}) {
					$menuItemEntity->{entityPicture} = $entity->{entity_picture};
				}

				Plugins::Assistant::Images::applyItemImage($menuItemEntity);
				$menuItemEntity->{nextWindow} = 'parent';
				$menuItemEntity->{type} = 'link';
				$menuItemEntity->{url} = \&AssistantAction;
				$menuItemEntity->{passthrough} = [{
					entity => $entity->{entity},
					domain => $menuItemEntity->{domain},
					state  => $menuItemEntity->{state},
				}];
				$menuItemEntity->{fetched} = 0;

				main::DEBUGLOG && $log->is_debug && $log->debug(
					'Updated menu item: ', $menuItemEntity->{entity},
					' state=', $menuItemEntity->{state} // '',
					' picture=', $menuItemEntity->{entityPicture} // '(none)',
					' icon=', $menuItemEntity->{entityIcon} // '(none)',
					' image=', $menuItemEntity->{image} // ''
				);
				return;
			}
		}
	}
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	if ($prefs->get('enabled') && $running && @$menuItems) {
		$cb->({
			items => $menuItems,
		});
		return;
	}

	my $message;
	if (!$prefs->get('enabled')) {
		$message = string('PLUGIN_ASSISTANT_STATUS_DISABLED');
	} elsif (!$running) {
		$message = string('PLUGIN_ASSISTANT_STATUS_CONNECTING');
	} else {
		$message = string('PLUGIN_ASSISTANT_STATUS_EMPTY');
	}

	$cb->({
		items => [{
			name => $message,
			type => 'text',
		}],
	});
}

1;
