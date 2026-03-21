package Plugins::Assistant::API;

use strict;
use base qw(Slim::Utils::Accessor);

use JSON::XS::VersionOneAndTwo;

use Plugins::Assistant::SimpleAsyncWS;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my %pendingCb;
our $ws = 0;
my $authenticated = 0;

my $log = logger('plugin.assistant');
my $prefs = preferences('plugin.assistant');
my $messageId = 1;

sub init {
	my ($class, $args) = @_;

	Slim::Utils::Timers::setTimer(
		undef,
		time(),
		\&_connect,
	);

}

sub getAreas {
	my ($self, $cb, $args) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('getAreas');

	$self->_write({
		type => 'config/area_registry/list'
	}, $cb);
}

sub getEntities {
	my ($self, $cb, $areaId) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('getEnteties for ', $areaId);

	$self->_write({
		type => 'extract_from_target',
		target => {
			area_id => [$areaId]
		},
	}, $cb);
}

sub subscribeEntities {
	my ($self, $cb, @entities) = @_;
	my $subscribeEntities = join ',', @entities;
	main::DEBUGLOG && $log->is_debug && $log->debug('subscribeEntities ', $subscribeEntities);

	$self->_write({
		type => 'subscribe_entities',
		entity_ids => $subscribeEntities
	}, $cb);
}

sub serviceAction {
	my ($self, $cb, $actionRequest) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('serviceAction ', JSON::XS->new->pretty->encode($actionRequest));

	$self->_write({
		type => 'call_service',
		domain => $actionRequest->{domain},
		service => $actionRequest->{service},
		target => {
			entity_id => $actionRequest->{entity}
		}
	}, $cb);
}

sub getImage {
	my ($self, $image) = @_;

	unless ($image) { return; }

	my $base = $prefs->get('connect') || '';
	unless ($base) {
		$log->error('Connect URL not set');
		return;
	}

	return $base.$image;
}

sub _connect {
	my ($class, $args) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('Connecting');

	# Build ws(s)://<host>/api/websocket from connect pref
	my $base = $prefs->get('connect') || '';
	unless ($base) {
		main::DEBUGLOG && $log->is_debug && $log->error('Connect URL not set');
		return;
	}
	my $hostpart = $base =~ m{^(https?://[^/]+)}i ? $1 : $base;
	my $ws_url = $hostpart;
	$ws_url =~ s{^https}{wss}i; $ws_url =~ s{^http}{ws}i;
	$ws_url .= '/api/websocket' unless $ws_url =~ m{/api/websocket$}i;

	main::DEBUGLOG && $log->is_debug && $log->debug('Connect URL: '.$ws_url);

	eval {
		$ws = Plugins::Assistant::SimpleAsyncWS->new(
			$ws_url,
			\&_connected,
			\&_connectError,
			\&_message,
			\&_readError
		);
	1;
	} or do {
		my $e = $@;
		$log->error('Failed connecting: ', $e);

		Slim::Utils::Timers::setTimer(
			undef,
			time() + 10,
			\&_connect,
		);
	}
}

sub _connectAuth {
	main::DEBUGLOG && $log->is_debug && $log->debug('Authenticating');
	my $token = $prefs->get('pass') || '';
	if ($ws && $token) {
		my $auth = encode_json({ type => 'auth', access_token => $token });
		$ws->send($auth);
	} else {
		$log->error('Token not set or no connection');
	}
}

sub _write {
	my ($self, $msg, $cb) = @_;

	die "Not authenticated" unless $authenticated;
	
	my $sentMessageId = $messageId++;
	my $sentMessage = {%$msg, id => $sentMessageId};
	$pendingCb{$sentMessageId} = $cb;

	my $req = encode_json($sentMessage);
	main::DEBUGLOG && $log->is_debug && $log->debug('Write message: ', $req);
	$ws->send($req) if $ws;
}

sub _message {
	my ($buf) = @_;

	my $payload;
	eval { $payload = decode_json($buf) };
	if ($@) {
		$log->error('Failed to decode websocket message');
		return;
	}

	if (!$ws) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Client not done connecting');
	}

	my $type = $payload->{type} || '';
	$log->debug('Got message: ', $type);
	if ($type eq 'auth_required') {
		Plugins::Assistant::API->_connectAuth();
		return;
	}
	elsif ($type eq 'auth_ok') {
		$authenticated = 1;
		return;
	}
	elsif ($type eq 'result' && defined $payload->{id}) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Got message type result and id='.$payload->{id}.' success='.$payload->{success});
		my $result = encode_json($payload->{result} || []);
		$pendingCb{$payload->{id}}->($result);
		return;
	}
	elsif ($type eq 'event' && defined $payload->{id}) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Got message type result and id='.$payload->{id});
		my $event = encode_json($payload->{event} || []);
		$pendingCb{$payload->{id}}->($event);
		return;
	}

	# Other message types can be handled/logged here
	main::INFOLOG && $log->is_info && $log->info('Unhandled message type: ' . $type);
}

sub _connected {
	main::DEBUGLOG && $log->is_debug && $log->debug('Connected');
}

sub _connectError {
	$log->error('WebSocket connection error');
}

sub _readError {
	$log->error('WebSocket read error');
}

sub getStatus {
	my ($self) = @_;
	
	return {
		connected      => $ws->{socket_open} // 0,
		listening      => $ws->{continue_listening} // 0,
		authenticated  => $ws->{client}->{hs}->is_done // 0,
		url            => $ws->{client}->{url}
	} if $ws;
}

sub shutdown {
	Slim::Utils::Timers::killTimers(undef, \&_connect);
	$ws->close() unless !$ws;
}

1;
