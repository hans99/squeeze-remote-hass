package Plugins::Assistant::API;

use strict;

use JSON::XS::VersionOneAndTwo;
use JSON::XS ();

use Plugins::Assistant::SimpleAsyncWS;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my %pendingCb;
my %subscriptionIds;
our $ws;
my $authenticated = 0;
my $connecting = 0;
my $shouldRun = 0;
my $onReadyCb;
my $onAuthFailedCb;
my $messageId = 1;
my $lastError = '';

my $log = logger('plugin.assistant');
my $prefs = preferences('plugin.assistant');

use constant RECONNECT_DELAY => 10;

sub init {
	my ($class, $args) = @_;

	$shouldRun = 1;
	$lastError = '';
	if ($args) {
		$onReadyCb = $args->{onReady} if ref $args->{onReady} eq 'CODE';
		$onAuthFailedCb = $args->{onAuthFailed} if ref $args->{onAuthFailed} eq 'CODE';
	}

	Slim::Utils::Timers::killTimers(undef, \&_connect);
	Slim::Utils::Timers::setTimer(
		undef,
		time(),
		\&_connect,
	);
}

sub getAreas {
	my ($self, $cb) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('getAreas');

	$self->_write({
		type => 'config/area_registry/list'
	}, $cb);
}

sub getEntities {
	my ($self, $cb, $areaId) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('getEntities for ', $areaId);

	$self->_write({
		type => 'extract_from_target',
		target => {
			area_id => [$areaId]
		},
		# HA requires a JSON bool, not integer 1
		expand_group => JSON::XS::true,
		# Keep default primary_entities_only (true): skip config/diagnostic entities
	}, $cb);
}

sub subscribeEntities {
	my ($self, $cb, @entities) = @_;
	return unless @entities;

	main::DEBUGLOG && $log->is_debug && $log->debug('subscribeEntities ', join(',', @entities));

	$self->_write({
		type => 'subscribe_entities',
		entity_ids => \@entities
	}, $cb, 1);
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

sub _connect {
	my ($class, $args) = @_;
	return unless $shouldRun;
	return if $connecting;
	# Socket already up (handshake done, auth in flight, or authenticated)
	return if $ws;

	main::DEBUGLOG && $log->is_debug && $log->debug('Connecting');

	my $base = $prefs->get('connect') || '';
	unless ($base) {
		$lastError = 'Connect URL not set';
		$log->error($lastError);
		return;
	}

	my $token = $prefs->get('pass') || '';
	unless ($token) {
		$lastError = 'Access token not set';
		$log->error($lastError);
		return;
	}

	my $hostpart = $base =~ m{^(https?://[^/]+)}i ? $1 : $base;
	my $ws_url = $hostpart;
	$ws_url =~ s{^https}{wss}i;
	$ws_url =~ s{^http}{ws}i;
	$ws_url .= '/api/websocket' unless $ws_url =~ m{/api/websocket$}i;

	main::DEBUGLOG && $log->is_debug && $log->debug('Connect URL: '.$ws_url);

	$connecting = 1;
	$authenticated = 0;
	_clearPending();

	# Assign $ws before handshake so HA auth_required (often in the same
	# TCP burst) can send the token immediately — otherwise HA closes ~10s later.
	$ws = Plugins::Assistant::SimpleAsyncWS->new();

	my $ok;
	eval {
		$ok = $ws->connect(
			$ws_url,
			\&_connected,
			\&_connectError,
			\&_message,
			\&_readError
		);
		1;
	} or do {
		my $e = $@ || 'unknown error';
		$lastError = "Failed connecting: $e";
		$log->error($lastError);
		eval { $ws->close() if $ws; };
		$ws = undef;
		$connecting = 0;
		_scheduleReconnect();
		return;
	};

	unless ($ok && $ws && $ws->{socket_open}) {
		eval { $ws->close() if $ws; };
		$ws = undef;
		$connecting = 0;
		$lastError ||= 'WebSocket connection failed';
		_scheduleReconnect() if $shouldRun;
	}
}

sub _connectAuth {
	main::DEBUGLOG && $log->is_debug && $log->debug('Authenticating');

	# Stale auth_required from a socket that was already torn down
	unless ($ws && $ws->{socket_open}) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Ignoring auth_required: no active websocket');
		return;
	}

	my $token = $prefs->get('pass') || '';
	unless ($token) {
		$lastError = 'Access token not set';
		$log->error($lastError);
		$connecting = 0;
		$authenticated = 0;
		$shouldRun = 0;
		_teardownSocket();
		$onAuthFailedCb->('Access token not set') if $onAuthFailedCb;
		return;
	}

	my $auth = encode_json({ type => 'auth', access_token => $token });
	$ws->send($auth);
}

sub _write {
	my ($self, $msg, $cb, $isSubscription) = @_;

	unless ($authenticated && $ws) {
		my $err = 'Not authenticated or no websocket connection';
		$log->error($err);
		$cb->(undef, $err) if $cb;
		return;
	}

	my $sentMessageId = $messageId++;
	my $sentMessage = {%$msg, id => $sentMessageId};
	$pendingCb{$sentMessageId} = {
		cb => $cb,
		subscription => $isSubscription ? 1 : 0,
	};
	$subscriptionIds{$sentMessageId} = 1 if $isSubscription;

	my $req = encode_json($sentMessage);
	main::DEBUGLOG && $log->is_debug && $log->debug('Write message: ', $req);
	$ws->send($req);
}

sub _decodeJson {
	my ($buf) = @_;

	return unless defined $buf && length $buf;

	my $payload;
	my $err;

	# Protocol::WebSocket may hand us UTF-8 octets or a Perl Unicode string.
	# Try octets first (decode_json / utf8=>1), then Unicode (utf8=>0).
	eval {
		$payload = decode_json($buf);
		1;
	} or do {
		$err = $@ || 'unknown JSON error';
		eval {
			$payload = JSON::XS->new->utf8(0)->decode($buf);
			$err = undef;
			1;
		} or do {
			$err = $@ || $err;
			$payload = undef;
		};
	};

	return ($payload, $err);
}

sub _message {
	my ($buf) = @_;

	unless (defined $buf && length $buf) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Ignoring empty websocket message');
		return;
	}

	my ($payload, $err) = _decodeJson($buf);
	if ($err || !defined $payload) {
		my $snippet = $buf;
		$snippet = substr($snippet, 0, 200) . '...' if length($snippet) > 200;
		$log->error('Failed to decode websocket message: ', $err || 'undef payload', ' buf=', $snippet);
		return;
	}

	my $type = $payload->{type} || '';
	main::DEBUGLOG && $log->is_debug && $log->debug('Got message: ', $type);

	if ($type eq 'auth_required') {
		Plugins::Assistant::API->_connectAuth();
		return;
	}
	elsif ($type eq 'auth_ok') {
		$authenticated = 1;
		$connecting = 0;
		$lastError = '';
		main::INFOLOG && $log->is_info && $log->info('Home Assistant authentication OK');
		$onReadyCb->() if $onReadyCb;
		return;
	}
	elsif ($type eq 'auth_invalid') {
		$authenticated = 0;
		$connecting = 0;
		$lastError = 'Authentication failed: ' . ($payload->{message} || 'invalid token');
		$log->error($lastError);
		$shouldRun = 0;
		_teardownSocket();
		$onAuthFailedCb->($payload->{message} || 'invalid token') if $onAuthFailedCb;
		return;
	}
	elsif ($type eq 'result' && defined $payload->{id}) {
		my $id = $payload->{id};
		my $entry = $pendingCb{$id};
		unless ($entry && ref $entry->{cb} eq 'CODE') {
			main::DEBUGLOG && $log->is_debug && $log->debug('No pending callback for result id=', $id);
			return;
		}

		unless ($payload->{success}) {
			my $err = $payload->{error}->{message} || 'request failed';
			$lastError = $err;
			$log->error('HA result error id=', $id, ' ', $err);
			$entry->{cb}->(undef, $err);
			delete $pendingCb{$id} unless $entry->{subscription};
			return;
		}

		# subscribe_entities acknowledges with an empty result, then sends events
		if ($entry->{subscription}) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Subscription confirmed id=', $id);
			return;
		}

		$entry->{cb}->($payload->{result});
		delete $pendingCb{$id};
		return;
	}
	elsif ($type eq 'event' && defined $payload->{id}) {
		my $id = $payload->{id};
		my $entry = $pendingCb{$id};
		unless ($entry && ref $entry->{cb} eq 'CODE') {
			main::DEBUGLOG && $log->is_debug && $log->debug('No pending callback for event id=', $id);
			return;
		}

		$entry->{cb}->($payload->{event} // {});
		return;
	}

	main::INFOLOG && $log->is_info && $log->info('Unhandled message type: ' . $type);
}

sub _connected {
	# Keep $connecting set until auth_ok / auth_invalid / error so a
	# reconnect timer cannot tear down the socket mid-handshake/auth.
	main::DEBUGLOG && $log->is_debug && $log->debug('WebSocket connected, awaiting authentication');
}

sub _connectError {
	my ($msg) = @_;

	# May fire during connect() before $ws is fully established
	return unless $ws || $connecting;

	$connecting = 0;
	$authenticated = 0;
	$lastError = 'WebSocket connection error' . ($msg ? ": $msg" : '');
	$log->error($lastError);
	_teardownSocket();
	_scheduleReconnect();
}

sub _readError {
	my ($msg) = @_;

	# Ignore cascaded failures after teardown (e.g. write-on-closed noise)
	return unless $ws || $connecting;

	$connecting = 0;
	$authenticated = 0;
	$lastError = 'WebSocket read error' . ($msg ? ": $msg" : '');
	$log->error($lastError);
	_teardownSocket();
	_scheduleReconnect();
}

sub _unsubscribeAll {
	return unless $ws && $authenticated && keys %subscriptionIds;

	foreach my $subId (keys %subscriptionIds) {
		my $req = encode_json({
			id => $messageId++,
			type => 'unsubscribe_events',
			subscription => 0 + $subId,
		});
		main::DEBUGLOG && $log->is_debug && $log->debug('Unsubscribe: ', $req);
		eval { $ws->send($req); };
	}
}

sub _teardownSocket {
	_clearPending();
	if ($ws) {
		eval { $ws->close(); };
		$ws = undef;
	}
}

sub _clearPending {
	%pendingCb = ();
	%subscriptionIds = ();
}

sub _scheduleReconnect {
	return unless $shouldRun;

	Slim::Utils::Timers::killTimers(undef, \&_connect);
	Slim::Utils::Timers::setTimer(
		undef,
		time() + RECONNECT_DELAY,
		\&_connect,
	);
}

sub getStatus {
	my ($self) = @_;

	return {
		connected     => ($ws && $ws->{socket_open}) ? 1 : 0,
		listening     => ($ws && $ws->{continue_listening}) ? 1 : 0,
		authenticated => $authenticated ? 1 : 0,
		running       => $shouldRun ? 1 : 0,
		connecting    => $connecting ? 1 : 0,
		lastError     => $lastError,
		url           => ($ws && $ws->{client}) ? $ws->{client}->{url} : undef,
	};
}

sub shutdown {
	my ($class) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug('API shutdown');

	$shouldRun = 0;
	$connecting = 0;

	Slim::Utils::Timers::killTimers(undef, \&_connect);

	# Best-effort unsubscribe while socket is still authenticated
	_unsubscribeAll() if $authenticated && $ws;

	$authenticated = 0;
	$onReadyCb = undef;
	$onAuthFailedCb = undef;
	$messageId = 1;

	_teardownSocket();
}

1;
