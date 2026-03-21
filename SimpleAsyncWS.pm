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

sub new {
	my ($class, $url, $cbConnected, $cbConnectFailed, $cbRead, $cbReadFailed) = @_;

	my $self = {
		client     => 0,
		tcp_socket   => 0,
		socket_open  => 0,
		continue_listening => 0,
		cb_Read  => 0,
		cb_Read_Failed => 0,
	};

	bless $self, $class;

	$self->_connect( $url, $cbConnected, $cbConnectFailed, $cbRead, $cbReadFailed);

	return $self;
}


sub close {
	my ($self) = @_;

	Slim::Utils::Timers::killTimers($self, \&_receive);

	main::INFOLOG && $log->is_info && $log->info("Close web socket connect with status: " . $self->{tcp_socket}->connected() );

	$self->{continue_listening} = 0;
	$self->{client}->disconnect;
	$self->{tcp_socket}->close if $self->{socket_open};
	$self->{socket_open} = 0;

	return;
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
	} elsif ($port == 433 ) {
		$proto = 'wss';
	}

	main::INFOLOG && $log->is_info && $log->info("Attempting to open socket to $proto://$host:$port...");

	if ($proto eq 'wss') {
		IO::Socket::SSL::set_defaults(SSL_verify_mode => Net::SSLeay::VERIFY_NONE())
		  if preferences('server')->get('insecureHTTPS');

		$self->{tcp_socket} = IO::Socket::SSL->new(
			PeerAddr => $host,
			PeerPort => "$proto($port)",
			Proto => 'tcp',
			Blocking => 1,
			SSL_startHandshake => 1,
		) or $cbConnectFailed->("Failed to connect to socket: $!,$SSL_ERROR");
	} else {
		$self->{tcp_socket} = IO::Socket::INET->new(
			PeerAddr => $host,
			PeerPort => "$proto($port)",
			Proto => 'tcp',
			Blocking => 1,
		) or $cbConnectFailed->("Failed to connect to socket: $!");
	}

	main::INFOLOG && $log->is_info && $log->info("Starting To Listen Async");
	$self->{cb_Read} = $cbRead;
	$self->{cb_Read_Failed} = $cbReadFailed;
	$self->{continue_listening} = 1;
	$self->_receive();


	main::INFOLOG && $log->is_info && $log->info("Trying to create Protocol::WebSocket::Client handler for $url...");
	$self->{client} = Protocol::WebSocket::Client->new(url => $url);
	$self->{socket_open} = 1;

	# Set up the various methods for the WS Protocol handler
	#  On Write: take the buffer (WebSocket packet) and send it on the socket.
	$self->{client}->on(
		write => sub {
			my $client = shift;
			my ($buf) = @_;

			#main::DEBUGLOG && $log->is_debug && $log->debug("Sending $buf ...");

			syswrite $self->{tcp_socket}, $buf if $self->{socket_open};
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
			$self->{tcp_socket}->close;
			die "Websocket error, socket closed";
		}
	);

	$self->{client}->on(
		read => sub {
			my $client = shift;
			my ($buf) = @_;
			main::INFOLOG && $log->is_info && $log->info("Message Recieved : $buf");

			$self->_read($buf);
		}
	);

	$self->{client}->on(
		ping => sub {
			my $client = shift;
			my ($buf) = @_;
			main::DEBUGLOG && $log->is_debug && $log->debug("Ping sent, sending pong : " . sprintf("%v02X", $buf));
			$client->pong($buf);
		}
	);

	main::INFOLOG && $log->is_info && $log->info("connecting to client");
	$self->{client}->connect;

	# read until handshake is complete.  This is blocking but should be over quickly.
	while (!$self->{client}->{hs}->is_done){
		my $recv_data;

		#my $bytes_read = sysread $self->{tcp_socket}, $recv_data, 16384;
		my $bytes_read = sysread $self->{tcp_socket}, $recv_data, 16;
		#$log->debug('<DATA> ', $recv_data);

		if (!defined $bytes_read) {
			$log->error("sysread on tcp_socket failed: $!");
			$cbConnectFailed->("WS Handshake failed");
			return;
		}elsif ($bytes_read == 0) {
			$log->error("Connection terminated.");
			$cbConnectFailed->("WS Handshake failed");
			return;
		}

		$self->{client}->read($recv_data);
	}
	return;
}


sub _read {
	my ($self, $buf) = @_;

	$self->{cb_Read}->($buf);

	return;
}


sub _receive {
	my ($self) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("Starting Listening");

	eval {
	if ($self->{continue_listening}) {

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
				$self->{cb_Read_Failed}->();

				# poll again in 1 second
				$self->_continueListen(1);

			} elsif ($bytes_read == 0) {

				# Remote socket closed
				$log->error("Connection terminated by remote. $!");

				$self->{cb_Read_Failed}->();

				close();

			} else {

				main::DEBUGLOG && $log->is_debug && $log->debug("Received data : $recv_data ");
				$self->{client}->read($recv_data);

				# if Async, poll immediately so that we pull everything off the socket if something is there.
				$self->_continueListen(1);

			}

		} else {

			main::DEBUGLOG && $log->is_debug && $log->debug("No Data Present, continue listening");

			# poll again in 1 second
			$self->_continueListen(1);

		}
	}
		} or do {
		my $e = $@;
		$log->error('Failed receive: ', $e);

	}
}


sub _continueListen {
	my ($self, $pollTimeSeconds) = @_;

	eval {
		Slim::Utils::Timers::setTimer($self, time() + $pollTimeSeconds, \&_receive);
	} or do {
		my $e = $@;
		$log->error('Failed timer: ', $e);

	}
}


sub send {
	my ($self, $buf) = @_;

	main::INFOLOG && $log->is_info && $log->info("Sending on web socket : $buf ");
	$self->{client}->write($buf);

	return;
}

1;
