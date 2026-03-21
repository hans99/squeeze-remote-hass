package Plugins::Assistant::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use JSON::XS::VersionOneAndTwo;
use Data::Dumper;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Assistant::API;
use Plugins::Assistant::Handlers;

use constant IMAGE_PATH => 'plugins/Assistant/html/images/';

my $log = Slim::Utils::Log->addLogCategory(
	{
		'category'     => 'plugin.assistant',
		'defaultLevel' => 'INFO',
		'description'  => 'PLUGIN_ASSISTANT',
	}
);

my $prefs = preferences('plugin.assistant');

my $menuItems;
my @domains = ('light', 'switch', 'cover');

sub initPlugin {
	my $class = shift;

	if (main::WEBUI) {
		require Plugins::Assistant::Settings;
		Plugins::Assistant::Settings->new();
	}

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'assistant',
		menu   => 'apps',
	);

	if ($prefs->get('enabled')) {
		require Plugins::Assistant::API;
		Plugins::Assistant::API->init();

		Slim::Utils::Timers::setTimer(
			undef,
			time() + 5,
			\&Assistant,
		);
	}
}

sub shutdownPlugin {
	main::DEBUGLOG && $log->is_debug && $log->debug('shutdown');
	main::DEBUGLOG && $log->is_debug && $log->debug(Dumper(Plugins::Assistant::API->getStatus()));

	Slim::Utils::Timers::killTimers(undef, \&Assistant);
	Plugins::Assistant::API->shutdown();
}

sub getDisplayName { 'PLUGIN_ASSISTANT' }

sub playerMenu {}

sub Assistant {
	main::INFOLOG && $log->is_info && $log->info('Assistant');

	eval {
		Plugins::Assistant::API->getAreas(sub {
			my $areas = shift;
			my $jsAreas = decode_json($areas);
			foreach my $area (@$jsAreas) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Area ", JSON::XS->new->pretty->encode($area));
				push @$menuItems, {
					name => $area->{name},
					image => _imagePath($area->{picture}),
					areaId => $area->{area_id},
				};
			};
			foreach my $menuItem (@$menuItems) {
				Plugins::Assistant::API->getEntities(sub {
					my $entities = shift;
					my @entitySubscriptions;
					my $jsEntities = decode_json($entities)->{referenced_entities};
					my $domain;
					my $items = [];
					foreach my $entity (@$jsEntities) {
						$domain = substr($entity, 0, index($entity, '.')),
						main::DEBUGLOG && $log->is_debug && $log->debug('Domain: ', $domain, ' - Entity: ', $entity);
						next unless grep {$_ eq $domain} @domains;
						push @entitySubscriptions, $entity;
						push @$items, {
							entity => $entity,
							domain => $domain
						}
					}
					if (@$items) {
						$menuItem->{items} = $items;
						main::DEBUGLOG && $log->is_debug && $log->debug('Entity subscriptions for ',$menuItem->{name} , ' - ', join ',', @entitySubscriptions);
						Plugins::Assistant::API->subscribeEntities(\&AssistanEntity, @entitySubscriptions);
					}
				}, $menuItem->{areaId});
			}
		});
		1;
	} or do {
		my $e = $@;
		$log->error('Failed to getAreas: ', $e);

		Slim::Utils::Timers::setTimer(
			undef,
			time() + 5,
			\&Assistant,
		);
	}
}

sub AssistantAction {
	my ($client, $cb, $params, $args) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('AssistantAction start ', JSON::XS->new->pretty->encode($args));

	my $service = $Plugins::Assistant::Handlers::service{$args->{domain}}($args->{state});
	my $actionRequest = {
		domain => $args->{domain},
		entity => $args->{entity},
		service => $service
	};

	Plugins::Assistant::API->serviceAction (sub {
		my $result = shift;
		main::DEBUGLOG && $log->is_debug && $log->debug('AssistantAction sent ', $result);
	}, $actionRequest);

	$cb->();
	return;
}

sub AssistanEntity {
	my $entities = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug('AssistanEntity entities ', $entities);
	my $decoded = JSON::XS->new->decode($entities);
	return unless ref $decoded eq 'HASH';

	my $key = (keys %{$decoded})[0];
	main::DEBUGLOG && $log->is_debug && $log->debug('Handler key ', $key);
	unless (ref($Plugins::Assistant::Handlers::entities{$key}) eq 'CODE') {
		die "No handler for key: $key\n";
	}
	my $entities = $Plugins::Assistant::Handlers::entities{$key}($decoded);

	foreach my $entity (@$entities) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Entity update ', JSON::XS->new->pretty->encode($entity));
		my $found = 0;
		foreach my $menuItem (@$menuItems) {
			my $menuItemItems = $menuItem->{items};
			foreach my $menuItemEntity (@$menuItemItems) {
				if ($menuItemEntity->{entity} eq $entity->{entity}) {
					$found = 1;
					$menuItemEntity->{name} //= $entity->{name};
					$menuItemEntity->{entityIcon} //= $entity->{icon};
					$menuItemEntity->{state} = $entity->{state};
					$menuItemEntity->{image} = _imageWithStatePath($menuItemEntity->{domain}, $entity->{state});
					$menuItemEntity->{nextWindow} = 'parent';
					$menuItemEntity->{type} = 'link';
					$menuItemEntity->{url} = \&AssistantAction;
					$menuItemEntity->{passthrough} = [{
						entity => $entity->{entity},
						domain => $menuItemEntity->{domain},
						state => $entity->{state}
					}];
					$menuItemEntity->{fetched} = 0;
					$log->debug('Updated menu item:');
					$log->debug(Dumper($menuItemEntity));
					last;
				}
			}
			last if $found;
		}
	}
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	if ($prefs->get('enabled') && $menuItems) {
		$cb->({
			items => $menuItems,
		});
		return;
	}
	die "Assistant is not enabled or something is wrong...";
}

sub _imagePath {
	my ($image) = @_;

	my $base = $prefs->get('connect') || '';

	unless ($base && $image) {
		return Plugins::Assistant::Plugin->_pluginDataFor('icon');
	}

	main::DEBUGLOG && $log->is_debug && $log->debug(' ImagePath: ', $base.$image);
	my $resize_url = Slim::Web::ImageProxy::proxiedImage($base.$image);
	main::DEBUGLOG && $log->is_debug && $log->debug(' ImagePathResize: ', $resize_url);

	return Slim::Web::ImageProxy::proxiedImage($base.$image);
}

sub _imageWithStatePath {
	my ($domain, $state) = @_;
	my $path;
	unless ($domain && $state) { return; }
	main::DEBUGLOG && $log->is_debug && $log->debug(' ImageWithStatePath: ', IMAGE_PATH.$domain.'_'.$state.'.png');
	return IMAGE_PATH.$domain.'_'.$state.'.png';
}

1;
