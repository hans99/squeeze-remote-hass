package Plugins::Assistant::SimpleAsyncWS;

# Lyrion Music Server Copyright 2024 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

# This class provides a non-blocking WebSockets client connection from Lyrion Music Server.

# This class is intended for plugins and other code needing simply to
# handle a persistent websockets connection.  If you have more complex
# needs consider writing a fuller implementation.

# This is a copy with some changes of the original SimpleWS file.

use strict;

use IO::Socket;
use IO::Socket::SSL;
use IO::Select;
use Protocol::WebSocket::Client;
use URI;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = logger('plugin.assistant');

# Construct only — call connect() after the caller has stored the object so
# early frames (e.g. HA auth_required) can already use $ws->send().
sub new {
	my ($class) = @_;

	my $self = {
		client             => 0,
		tcp_socket         => 0,
		socket_open        => 0,
		continue_listening => 0,
		cb_Read            => 0,
		cb_Read_Failed     => 0,
	};

	return bless $self, $class;
}

# Returns true on successful handshake.
sub connect {
	my ($self, $url, $cbConnected, $cbConnectFailed, $cbRead, $cbReadFailed) = @_;

	$self->_connect($url, $cbConnected, $cbConnectFailed, $cbRead, $cbReadFailed);

	return ($self->{socket_open} && $self->{client}) ? 1 : 0;
}

sub close {
	my ($self) = @_;

	Slim::Utils::Timers::killTimers($self, \&_receive);

	$self->{continue_listening} = 0;
	$self->{cb_Read} = 0;
	$self->{cb_Read_Failed} = 0;

	my $wasOpen = $self->{socket_open};
	my $client = $self->{client};
	my $tcp = $self->{tcp_socket};

	# Mark closed first so write/disconnect callbacks no-op
	$self->{socket_open} = 0;
	$self->{client} = 0;
	$self->{tcp_socket} = 0;

	if ($wasOpen && $tcp) {
		main::INFOLOG && $log->is_info && $log->info(
			'Close web socket connect with status: ' . (eval { $tcp->connected() } || 0)
		);
	}

	# Only send a WS close frame if we still believe the socket is writable.
	# After a remote hangup, disconnect() would warn "write() on closed WebSocket".
	if ($wasOpen && $client && $tcp && eval { $tcp->connected() }) {
		eval { $client->disconnect; };
	}
	eval { $tcp->close if $tcp; };

	return;
}

sub _fail {
	my ($self, $msg) = @_;

	$self->{continue_listening} = 0;
	my $cb = $self->{cb_Read_Failed};
	$self->{cb_Read_Failed} = 0;
	$self->{cb_Read} = 0;
	$cb->($msg) if $cb;
}

sub _connect {
	my ($self, $url, $cbConnected, $cbConnectFailed, $cbRead, $cbReadFailed) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("Connecting to webSocket $url");

	my $uri = URI->new($url);
	my $proto = $uri->scheme;
	my $host = $uri->host;
	my $path = $uri->path;
	my $port = $uri->port;

	if (! (($proto =~ /ws|wss/) && $host) ) {
		$log->warn("Failed to parse $url");
		$cbConnectFailed->("Failed to parse Host/Port for ws URL from $url");
		return;
	} elsif ($port == 443) {
		$proto = 'wss';
	}

	main::INFOLOG && $log->is_info && $log->info("Attempting to open socket to $proto://$host:$port...");

	if ($proto eq 'wss') {
		IO::Socket::SSL::set_defaults(SSL_verify_mode => Net::SSLeay::VERIFY_NONE())
		  if preferences('server')->get('insecureHTTPS');

		$self->{tcp_socket} = IO::Socket::SSL->new(
			PeerAddr => $host,
			PeerPort => $port,
			Proto => 'tcp',
			Blocking => 1,
			SSL_startHandshake => 1,
		);
		unless ($self->{tcp_socket}) {
			$cbConnectFailed->("Failed to connect to socket: $!,$SSL_ERROR");
			return;
		}
	} else {
		$self->{tcp_socket} = IO::Socket::INET->new(
			PeerAddr => $host,
			PeerPort => $port,
			Proto => 'tcp',
			Blocking => 1,
		);
		unless ($self->{tcp_socket}) {
			$cbConnectFailed->("Failed to connect to socket: $!");
			return;
		}
	}

	$self->{cb_Read} = $cbRead;
	$self->{cb_Read_Failed} = $cbReadFailed;

	main::INFOLOG && $log->is_info && $log->info("Trying to create Protocol::WebSocket::Client handler for $url...");
	$self->{client} = Protocol::WebSocket::Client->new(url => $url);
	$self->{socket_open} = 1;

	# Set up the various methods for the WS Protocol handler
	#  On Write: take the buffer (WebSocket packet) and send it on the socket.
	$self->{client}->on(
		write => sub {
			my $client = shift;
			my ($buf) = @_;

			syswrite $self->{tcp_socket}, $buf if $self->{socket_open} && $self->{tcp_socket};
		}
	);

	# On Connect: this is what happens after the handshake succeeds, and we
	#  are "connected" to the service.
	$self->{client}->on(
		connect => sub {
			my $client = shift;
			main::INFOLOG && $log->is_info && $log->info("Successfully Connected to $url...", $client);
			$cbConnected->();
		}
	);

	$self->{client}->on(
		error => sub {
			my $client = shift;
			my ($buf) = @_;

			$log->error("ERROR ON WEBSOCKET: $buf");
			$self->{socket_open} = 0;
			$self->{continue_listening} = 0;
			eval { $self->{tcp_socket}->close if $self->{tcp_socket}; };
			$self->_fail("Websocket error: $buf");
		}
	);

	$self->{client}->on(
		read => sub {
			my $client = shift;
			my ($buf) = @_;
			main::DEBUGLOG && $log->is_debug && $log->debug("Message Recieved : $buf");

			$self->_read($buf);
		}
	);

	$self->{client}->on(
		ping => sub {
			my $client = shift;
			my ($buf) = @_;
			main::DEBUGLOG && $log->is_debug && $log->debug("Ping sent, sending pong : " . sprintf("%v02X", $buf));
			$client->pong($buf) if $self->{socket_open};
		}
	);

	main::INFOLOG && $log->is_info && $log->info("connecting to client");
	$self->{client}->connect;

	# Read until handshake is complete. Blocking, but should finish quickly.
	# HA often sends auth_required in the same burst — read callbacks may fire here.
	while ($self->{client} && !$self->{client}->{hs}->is_done) {
		my $recv_data;

		my $bytes_read = sysread $self->{tcp_socket}, $recv_data, 16384;

		if (!defined $bytes_read) {
			$log->error("sysread on tcp_socket failed: $!");
			$self->close();
			$cbConnectFailed->("WS Handshake failed");
			return;
		} elsif ($bytes_read == 0) {
			$log->error("Connection terminated.");
			$self->close();
			$cbConnectFailed->("WS Handshake failed");
			return;
		}

		$self->{client}->read($recv_data);
	}

	# Start async receive loop only after handshake succeeds
	$self->{continue_listening} = 1;
	$self->_continueListen(0);

	return;
}


sub _read {
	my ($self, $buf) = @_;

	$self->{cb_Read}->($buf) if $self->{cb_Read};

	return;
}


sub _receive {
	my ($self) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("Starting Listening");

	eval {
		if ($self->{continue_listening} && $self->{tcp_socket} && $self->{client}) {

			my $s = IO::Select->new();
			$s->add($self->{tcp_socket});
			$! = 0;

			main::DEBUGLOG && $log->is_debug && $log->debug("Checking the socket for something to read");
			my @ready = $s->can_read(0);

			if (@ready) {
				my $recv_data;
				my $bytes_read = sysread $ready[0], $recv_data, 16384;
				if (!defined $bytes_read) {

					$log->error("Error reading from socket : $!");
					$self->_fail("Error reading from socket: $!");
					$self->close();

				} elsif ($bytes_read == 0) {

					# Remote socket closed — do not Protocol::WebSocket disconnect()
					$log->error("Connection terminated by remote. $!");
					$self->_fail("Connection terminated by remote");
					$self->close();

				} else {

					main::DEBUGLOG && $log->is_debug && $log->debug("Received data : $recv_data ");
					$self->{client}->read($recv_data) if $self->{socket_open} && $self->{client};

					# Poll again soon so remaining buffered data is drained.
					$self->_continueListen(0);
				}

			} else {

				main::DEBUGLOG && $log->is_debug && $log->debug("No Data Present, continue listening");

				# poll again in 1 second
				$self->_continueListen(1);

			}
		}
	} or do {
		my $e = $@ || 'unknown error';
		$log->error('Failed receive: ', $e);
		$self->_fail("Failed receive: $e");
		$self->close();
	};
}


sub _continueListen {
	my ($self, $pollTimeSeconds) = @_;

	return unless $self->{continue_listening};

	eval {
		Slim::Utils::Timers::setTimer($self, time() + $pollTimeSeconds, \&_receive);
	} or do {
		my $e = $@ || 'unknown error';
		$log->error('Failed timer: ', $e);
	};
}


sub send {
	my ($self, $buf) = @_;

	unless ($self->{client} && $self->{socket_open}) {
		$log->error('Cannot send: websocket not open');
		return;
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("Sending on web socket : $buf ");
	$self->{client}->write($buf);

	return;
}

1;
