package Plugins::Assistant::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);
use JSON::XS::VersionOneAndTwo;
use threads::shared;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Assistant::HASS;

my $log = Slim::Utils::Log->addLogCategory(
	{
		'category'     => 'plugin.assistant',
		'defaultLevel' => 'ERROR',
		'description'  => 'PLUGIN_ASSISTANT',
	}
);

my $prefs = preferences('plugin.assistant');

my $cache = Slim::Utils::Cache->new('assistant', 3);


sub initPlugin {
	my $class = shift;

	Plugins::Assistant::HASS->init($cache);

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'assistant',
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);

	if (main::WEBUI) {
		require Plugins::Assistant::Settings;
		Plugins::Assistant::Settings->new();
	}
}

sub getDisplayName { 'PLUGIN_ASSISTANT' }


# don't add this plugin to the Extras menu
sub playerMenu {}


sub handleFeed {
	my ($client, $cb, $args) = @_;

	my $params = $args->{params};

	# Only groups in first level
	if (defined $prefs->get('show_home') && $prefs->get('show_home') == 1) {
		$args->{'showhome'} = $prefs->get('show_home');
	}

	getItems($client,$cb,$params,$args);
}


sub getItems {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Assistant::HASS::getEntities(
		$client,
		sub {
			my $entities = shift;
			my $items = [];

			foreach my $entity(@$entities) {
				my ($namespace, $name) = split('\.', $entity->{'entity_id'}, 2);

				my $order = 999;
				if (defined $entity->{'attributes'}->{'order'}) {
					$order = $entity->{'attributes'}->{'order'};
				}

				# If current entity is included in args and this is a group,
				# change namespace to the namespace of all sub entities
				# Note: Currently only light is supported
				if ($namespace eq 'group' && $entity->{'entity_id'} eq $args->{'entity_id'}) {
					$namespace = 'light';
				}

				$log->debug('Namespace: ', $namespace, ' Name: ', $name, ' - ', $order);

				if ($namespace eq 'group' && (!$entity->{'attributes'}->{'hidden'} || $entity->{'attributes'}->{'view'})) {

					# Add current to request list if all sub entities the same
					# Add current entity id to args
					# Note: Currently only light is supported
					my $entity_ids = $entity->{'attributes'}->{'entity_id'};
					if (!grep(!/light\./, @{$entity_ids})) {
						push @$entity_ids, $entity->{'entity_id'};
					}

					push @$items,
					  {
						name => $entity->{'attributes'}->{'friendly_name'},
						order => $order,
						type => 'link',
						url  => \&getItems,
						passthrough => [
							{
								entity_id => $entity->{'entity_id'},
								entity_ids => $entity_ids,
							}
						]
					  };

				} elsif ($namespace eq 'light' && defined $args->{'showhome'}) {

					push @$items,{
						name => $entity->{'attributes'}->{'friendly_name'},
						image => 'plugins/Assistant/html/images/light_'.$entity->{'state'}.'.png',
						order => $order,
						type => 'link',
						url  => \&toggleLightEntity,
						passthrough => [
							{
								entity_id => $entity->{'entity_id'},
								state => $entity->{'state'},
							}
						],

						#nextWindow => 'refresh',
					};

				} elsif ($namespace eq 'sensor' && defined $args->{'showhome'}) {

					push @$items,
					  {
						name => $entity->{'attributes'}->{'friendly_name'}.' '.$entity->{'state'}.$entity->{'attributes'}->{'unit_of_measurement'},
						order => $order,
						type => 'text',
					  };

				} elsif (defined $args->{'showhome'}) {

					push @$items,
					  {
						name => $entity->{'attributes'}->{'friendly_name'}.' '.$entity->{'state'},
						order => $order,
						type => 'text',
					  };

				}
			}
			$items = [ sort { uc($a->{order}) cmp uc($b->{order}) } @$items ];
			$cb->(
				{
					items => $items,
				}
			);
		},
		$params,
		{
			entity_ids => $args->{'entity_ids'},
		},
	);
}


sub toggleLightEntity {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Assistant::HASS::toggleLightEntity(
		$client,
		sub {
			my $items = [];

			push @$items,
			  {
				name        => 'Toggled Light',
				type        => 'text',
				showBriefly => 1,
			  };
			$cb->(
				{
					items => $items,
				}
			);
		},
		$params,
		$args,
	);
}

1;