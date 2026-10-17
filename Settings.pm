package Plugins::Assistant::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

my $prefs = preferences('plugin.assistant');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_ASSISTANT');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Assistant/settings.html');
}

sub prefs {
	return ($prefs, qw(connect pass enabled));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ($params->{saveSettings}) {
		$params->{pref_enabled} = defined $params->{pref_enabled} ? 1 : 0;

		my $connect = $params->{pref_connect} // '';
		my $pass    = $params->{pref_pass} // '';
		$connect =~ s/^\s+|\s+$//g;
		$pass    =~ s/^\s+|\s+$//g;
		$params->{pref_connect} = $connect;
		$params->{pref_pass} = $pass;

		my @errors;

		if ($params->{pref_enabled} || length $connect || length $pass) {
			if (!length $connect) {
				push @errors, string('PLUGIN_ASSISTANT_ERR_CONNECT_REQUIRED');
			}
			elsif ($connect !~ m{^https?://[^/\s]+}i) {
				push @errors, string('PLUGIN_ASSISTANT_ERR_CONNECT_INVALID');
			}

			if ($params->{pref_enabled} && !length $pass) {
				push @errors, string('PLUGIN_ASSISTANT_ERR_TOKEN_REQUIRED');
			}
		}

		if (@errors) {
			$params->{warning} = join(' ', @errors);
			# Keep submitted values on the form; do not persist or restart
			$params->{prefs}->{connect} = $connect;
			$params->{prefs}->{pass} = $pass;
			$params->{prefs}->{enabled} = $params->{pref_enabled};
			$params->{prefs}->{pref_enabled} = $params->{pref_enabled};
		}
		else {
			$prefs->set('connect', $connect);
			$prefs->set('pass', $pass);
			$prefs->set('enabled', $params->{pref_enabled});
			$prefs->savenow();

			if ($params->{pref_enabled}) {
				Plugins::Assistant::Plugin->restart();
			}
			else {
				Plugins::Assistant::Plugin->stop();
				Plugins::Assistant::Plugin->removeHomePins();
			}
		}
	}

	_addStatus($params);

	return $class->SUPER::handler($client, $params, $callback, @args);
}

sub _addStatus {
	my ($params) = @_;

	require Plugins::Assistant::API;
	my $status = eval { Plugins::Assistant::API->getStatus() } || {};
	my $enabled = $prefs->get('enabled');

	my $label;
	if (!$enabled) {
		$label = string('PLUGIN_ASSISTANT_STATUS_DISABLED');
	}
	elsif ($status->{authenticated}) {
		$label = string('PLUGIN_ASSISTANT_STATUS_CONNECTED');
	}
	elsif ($status->{connecting} || $status->{running}) {
		$label = string('PLUGIN_ASSISTANT_STATUS_CONNECTING');
	}
	else {
		$label = string('PLUGIN_ASSISTANT_STATUS_DISCONNECTED');
	}

	if ($status->{lastError}) {
		$label .= ' — ' . $status->{lastError};
	}

	$params->{assistant_status} = $label;
}

1;
