package Plugins::Assistant::HASS;

use strict;
use JSON::XS::VersionOneAndTwo;
use threads::shared;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Networking::SqueezeNetwork;
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
				$log->error("Error (".$prefs->get('connect')."): $_[1]");
			},
			{
				timeout => 5,
			},
		);

		$http->get(
			$prefs->get('connect'),
			'Authorization' => "Bearer ".$prefs->get('pass'),
			'Content-Type' => 'application/json',
			'charset' => 'UTF-8',
		);
	}
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

	my $url = $prefs->get('connect').'states';
	if (defined $args->{'entity_id'}) {
		$url = $url.'/'.$args->{'entity_id'};
	}

	$log->debug('Get Entity: ', $url);

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
			$log->error("Error (".$url."): $_[1]");
			$cb->();
		},
		{
			params  => $params,
			timeout => 5,
		},
	);

	$http->get(
		$url,
		'Authorization' => "Bearer ".$prefs->get('pass'),
		'Content-Type' => 'application/json',
		'charset' => 'UTF-8',
	);
}


sub services {
	my ($client, $cb, $params, $args) = @_;


	my $url = $prefs->get('connect').'services/'.$args->{'domain'}.'/'.$args->{'service'};
	my $req->{'entity_id'} = $args->{'entity_id'};

	$log->debug($url.' { '.$req->{'entity_id'}.' }');

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $params   = $response->params('params');
			my $result;
			if ( $response->headers->content_type =~ /json/ ) {
				$log->debug($response->content);
				$result = decode_json($response->content);
			}
			$cb->($client, $result, $params, $args);
		},
		sub {
			$log->error("Error (".$url."): $_[1]");
			$cb->();
		},
		{
			timeout => 5,
		},
	);

	$http->post(
		$url,
		'Authorization' => "Bearer ".$prefs->get('pass'),
		'Content-Type' => 'application/json',
		'charset' => 'UTF-8',
		encode_json($req),
	);

}


1;
