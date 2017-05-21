package Plugins::Assistant::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.assistant');


sub name {
	return 'PLUGIN_ASSISTANT';
}


sub prefs {
	return ($prefs, qw(connect pass show_home));
}


sub page {
	return 'plugins/Assistant/settings.html';
}


sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ( $params->{saveSettings} ) {
		$prefs->set('connect', $params->{pref_connect});
		$prefs->set('pass', $params->{pref_pass});
		$prefs->set('pref_show_home', $params->{pref_show_home});
		$prefs->savenow();
	}

	if ( $prefs->get('connect') ) {
		Plugins::Assistant::HASS->testHassConnection();
	}

	return $class->SUPER::handler($client, $params);
}

1;