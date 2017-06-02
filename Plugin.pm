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
my %entities;


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

	Plugins::Assistant::HASS::getEntities(
		$client,
		sub {
			my $tentities = shift;

			my $items = [];
			my $order = 1000;

			foreach my $tentity(@$tentities) {
				$entities{$tentity->{'entity_id'}} = $tentity;
			}

			foreach my $id(keys %entities) {

				my ($namespace, $name) = split('\.', $id, 2);
				if (($namespace eq 'group' && (!$entities{$id}->{'attributes'}->{'hidden'} || $entities{$id}->{'attributes'}->{'view'}))
					|| $prefs->get('show_home') == 1) {

					my $item = getItem($id);
					$item->{'order'} = $order++ if (!defined $item->{'order'});
					$log->debug('getEntities: '.$id.' - '.$item->{'name'}.' - '.$item->{'order'});
					push @$items, $item;
				}
			}
			$items = [ sort { uc($a->{order}) cmp uc($b->{order}) } @$items ];
			$cb->(
				{
					items => $items,
				}
			);
		},
		$args,
	);
}


sub getItem {

	my ($id) = @_;
	my ($namespace, $name) = split('\.', $id, 2);

	$log->debug($id);

	if ($namespace eq 'group') {

		my $gorder = 2000;
		my $gitems = [];

		# Add current to request list if all sub entities the same
		# Add current entity id to args
		# Note: Currently only light is supported
		if (!grep(!/light\./, @{$entities{$id}->{'attributes'}->{'entity_id'}})) {

			$namespace = 'light';

			my $tid = $namespace.'.'.$name;
			$entities{$tid} = $entities{$id};
			push @{$entities{$id}->{'attributes'}->{'entity_id'}}, $tid;
		}

		foreach my $gid(@{$entities{$id}->{'attributes'}->{'entity_id'}}) {
			my $gitem = getItem($gid, %entities);
			$gitem->{'order'} = $gorder++ if (!defined $gitem->{'order'});

			$log->debug($id.' - '.$gitem->{'name'}.' - '.$gitem->{'order'});
			push @$gitems, $gitem;
		}
		$gitems = [ sort { uc($a->{order}) cmp uc($b->{order}) } @$gitems ];

		return {
			name => $entities{$id}->{'attributes'}->{'friendly_name'},
			image => 'plugins/Assistant/html/images/'.$namespace.'_'.$entities{$id}->{'state'}.'.png',
			order => $entities{$id}->{'attributes'}->{'order'},
			type => 'link',
			items => $gitems,
		};

	} elsif ($namespace eq 'light') {

		return {
			name => $entities{$id}->{'attributes'}->{'friendly_name'},
			image => 'plugins/Assistant/html/images/light_'.$entities{$id}->{'state'}.'.png',
			order => $entities{$id}->{'attributes'}->{'order'},
			nextWindow => 'refresh',
			type => 'link',
			url  => \&servicesCall,
			passthrough => [
				{
					entity_id => $entities{$id}->{'entity_id'},
					domain => $namespace,
					service => $entities{$id}->{'state'} eq 'on' ? 'turn_off' : 'turn_on',
				}
			],
		};

	} elsif ($namespace eq 'sensor') {

		my $name = $entities{$id}->{'attributes'}->{'friendly_name'}.' '.$entities{$id}->{'state'}.$entities{$id}->{'attributes'}->{'unit_of_measurement'};
		$name =~ s/\R//g;

		return {
			name => $name,
			order => $entities{$id}->{'attributes'}->{'order'},
			type => 'text',
		};

	} else {

		return {
			name => $entities{$id}->{'attributes'}->{'friendly_name'}.' '.$entities{$id}->{'state'},
			order => $entities{$id}->{'attributes'}->{'order'},
			type => 'text',
		};
	}
}


sub servicesCall {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Assistant::HASS::services(
		$client,
		sub {
			my ($client, $result, $params, $args) = @_;

			my $newstate = '';
			foreach my $entity(@$result) {
				if ($entity->{'entity_id'} eq $args->{'entity_id'}) {
					$newstate = $entity->{'state'};
				}
			}

			my $items = [];
			push @$items,
			  {
				name        => $entities{$args->{'entity_id'}}->{'attributes'}->{'friendly_name'}.' '.$newstate,
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