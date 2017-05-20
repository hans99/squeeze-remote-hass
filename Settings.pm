package Plugins::Assistant::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.assistant');


sub name {
	return 'PLUGIN_ASSISTANT';
}


sub prefs {
	return ($prefs, 'connect');
}


sub page {
	return 'plugins/Assistant/settings.html';
}

1;