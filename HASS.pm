package Plugins::Assistant::HASS;

use strict;
use JSON::XS::VersionOneAndTwo;
use threads::shared;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = logger('plugin.assistant');
my $cache;
my $prefs = preferences('plugin.assistant');


sub init {
	($cache) = @_;
}


sub testHassConnection {
	my ( $client, $cb, $params, $args ) = @_;

	if (defined $prefs->get('connect')) {
		my $http = Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$log->info("Connected to Home Assistant at (".$prefs->get('connect').")");
			},
			sub {
				$log->warn("Warning (".$prefs->get('connect')."): $_[1]");
			},
			{
				timeout => 5,
			},
		);

		$http->get(
			$prefs->get('connect'),
			'Content-Type' => 'application/json',
			'charset' => 'UTF-8',
			access(),
		);
	}
}

sub access() {
	if ($prefs->get('pass')) {
		$log->debug('PASS');
		return 'x-ha-access' => $prefs->get('pass');
	}
	return !defined;
}

sub getEntities {
	my ( $client, $cb, $params, $args ) = @_;

	our $result :shared = [];
	our $counter :shared = 0;

	if (defined $args->{'entity_ids'}) {
		foreach my $entity_id(@{$args->{'entity_ids'}}) {

			$counter++;
			Plugins::Assistant::HASS::getEntity(
				$client,
				sub {
					my $entity = shift;
					if (defined $entity) {
						push @$result, $entity;
					}
					$counter--;
					if ($counter <= 0) {
						$cb->($result);
					}
				},
				$params,
				{
					entity_id => $entity_id,
				},
			);
		}
	} else {

		Plugins::Assistant::HASS::getEntity(
			$client,
			sub {
				my $entities = shift;
				foreach my $entity(@$entities) {
					push @$result, $entity;
				}
				$cb->($result);
			},
			$params,
			{},
		);
	}
}


sub getEntity {
	my ($client, $cb, $params, $args) = @_;

	my $localurl = $prefs->get('connect').'states';
	if (defined $args->{'entity_id'}) {
		$localurl = $localurl.'/'.$args->{'entity_id'};
	}

	$log->debug('Get Entity: ', $localurl);

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $params   = $response->params('params');
			my $result;
			if ( $response->headers->content_type =~ /json/ ) {
				$result = decode_json($response->content);
			}
			$cb->($result);
		},
		sub {
			$log->warn("Warning (".$localurl."): $_[1]");
			$cb->();
		},
		{
			params  => $params,
			timeout => 5,
		},
	);

	$http->get(
		$localurl,
		'Content-Type' => 'application/json',
		'charset' => 'UTF-8',
		access(),
	);
}


sub toggleLightEntity {
	my ($client, $cb, $params, $args) = @_;

	my $localurl = $prefs->get('connect').'services/light/toggle';
	my $req->{'entity_id'} = $args->{'entity_id'};

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $params   = $response->params('params');
			my $result;
			if ( $response->headers->content_type =~ /json/ ) {
				$result = decode_json($response->content);
			}
			$cb->($result);
		},
		sub {
			$log->error("error: $_[1]");
			$cb->();
		},
		{
			timeout => 5,
		},
	);

	$http->post(
		$localurl,
		'Content-Type' => 'application/json',
		'charset' => 'UTF-8',
		encode_json($req),
		access(),
	);
}

1;
