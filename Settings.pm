package Plugins::Assistant::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

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

	$params->{'pref_enabled'} = defined $params->{'pref_enabled'} ? 1 : 0;

	if ( $params->{saveSettings} ) {
		$prefs->set('connect', $params->{pref_connect});
		$prefs->set('pass', $params->{pref_pass});
		$prefs->set('enabled', $params->{pref_enabled});
		$prefs->savenow();

		if ( $params->{'pref_enabled'} ) {
			Plugins::Assistant::Plugin->initPlugin();
		} else {
			Plugins::Assistant::Plugin->shutdownPlugin();
		}
	}

	return $class->SUPER::handler($client, $params, $callback, @args);
}
1;
