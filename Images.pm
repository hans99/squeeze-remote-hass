package Plugins::Assistant::Images;

# ImageProxy handlers and menu artwork helpers for Home Assistant entities.
# Kept separate from Plugin.pm (lifecycle/OPML) per LMS plugin layout (cf. AudioAddict::API).

use strict;

use Digest::MD5 qw(md5_hex);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Assistant::Mdi;

use constant IMAGE_PATH => 'plugins/Assistant/html/images/';
use constant HA_IMAGE_SCHEME => 'assistant-ha:';
use constant MDI_IMAGE_SCHEME => 'assistant-mdi:';
# Approximate Home Assistant frontend state colors
use constant MDI_COLOR_ACTIVE   => 'ffa000';
use constant MDI_COLOR_INACTIVE => '44739e';
use constant MDI_COLOR_UNAVAIL  => '6c6c6c';

my $log = logger('plugin.assistant');
my $prefs = preferences('plugin.assistant');

sub register {
	eval {
		require Slim::Web::ImageProxy;
		require Slim::Networking::SimpleAsyncHTTP;
		require Slim::Utils::Misc;

		Slim::Web::ImageProxy->registerHandler(
			match => qr/^assistant-ha:/,
			func  => \&_haImageProxyHandler,
		);
		Slim::Web::ImageProxy->registerHandler(
			match => qr/^assistant-mdi:/,
			func  => \&_mdiImageProxyHandler,
		);
		main::INFOLOG && $log->is_info && $log->info('Registered HA/MDI image proxy handlers');
		1;
	} or do {
		$log->error('Failed to register image proxy handlers: ', $@ || '');
	};
}

sub applyItemImage {
	my ($item) = @_;
	return unless $item && ref $item eq 'HASH';

	my $image = entityImage(
		$item->{entityPicture},
		$item->{entityIcon},
		$item->{domain},
		$item->{state},
	);
	$item->{image} = $image;
	$item->{icon} = $image;
	$item->{'icon-id'} = $image;
}

# Priority: entity_picture → mdi: icon → local domain/state PNG
sub entityImage {
	my ($entityPicture, $mdiIcon, $domain, $state) = @_;

	if (my $url = haMediaUrl($entityPicture)) {
		return $url;
	}

	$mdiIcon ||= _defaultMdiForDomain($domain, $state);

	if (my $url = _mdiImage($mdiIcon, $domain, $state)) {
		return $url;
	}

	return imageWithStatePath($domain, $state);
}

sub imagePath {
	my ($image) = @_;

	return haMediaUrl($image)
		|| Plugins::Assistant::Plugin->_pluginDataFor('icon');
}

sub imageWithStatePath {
	my ($domain, $state) = @_;
	return unless $domain && defined $state;

	if ($domain eq 'cover') {
		$state = 'open'   if $state eq 'opening';
		$state = 'closed' if $state eq 'closing' || $state eq 'unavailable' || $state eq 'unknown';
	}
	elsif ($domain eq 'light' || $domain eq 'switch') {
		$state = ($state eq 'on') ? 'on' : 'off';
	}

	my $path = IMAGE_PATH.$domain.'_'.$state.'.png';
	main::DEBUGLOG && $log->is_debug && $log->debug('ImageWithStatePath: ', $path);
	return $path;
}

sub haMediaUrl {
	my ($path) = @_;
	return unless defined $path && length $path;

	if ($path =~ m{^media-source:}i) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Skipping media-source picture: ', $path);
		return;
	}

	require Slim::Web::ImageProxy;

	if ($path =~ m{^https?://}i) {
		my $base = $prefs->get('connect') || '';
		if ($base) {
			$base =~ s{/$}{};
			my $baseHost = $base;
			$baseHost =~ s{^https?://}{}i;
			if ($path =~ m{^https?://\Q$baseHost\E(/.*)$}i) {
				my $rel = $1;
				main::DEBUGLOG && $log->is_debug && $log->debug('HA media (auth proxy): ', $rel);
				return Slim::Web::ImageProxy::proxiedImage(HA_IMAGE_SCHEME.$rel, 1);
			}
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('HA media (external): ', $path);
		return Slim::Web::ImageProxy::proxiedImage($path);
	}

	$path = '/'.$path unless $path =~ m{^/};
	main::DEBUGLOG && $log->is_debug && $log->debug('HA media (auth proxy): ', $path);
	return Slim::Web::ImageProxy::proxiedImage(HA_IMAGE_SCHEME.$path, 1);
}

sub _defaultMdiForDomain {
	my ($domain, $state) = @_;
	return unless $domain;

	if ($domain eq 'light') {
		return ($state && $state eq 'on') ? 'mdi:lightbulb-on' : 'mdi:lightbulb-outline';
	}
	if ($domain eq 'switch') {
		return ($state && $state eq 'on') ? 'mdi:toggle-switch' : 'mdi:toggle-switch-off-outline';
	}
	if ($domain eq 'cover') {
		return ($state && ($state eq 'open' || $state eq 'opening'))
			? 'mdi:window-shutter-open'
			: 'mdi:window-shutter';
	}
	return;
}

sub _mdiStateColor {
	my ($domain, $state) = @_;

	$state = defined $state ? lc $state : '';

	return MDI_COLOR_UNAVAIL
		if $state eq '' || $state eq 'unavailable' || $state eq 'unknown';

	if ($domain && $domain eq 'cover') {
		return MDI_COLOR_ACTIVE
			if $state eq 'open' || $state eq 'opening';
		return MDI_COLOR_INACTIVE;
	}

	return MDI_COLOR_ACTIVE if $state eq 'on' || $state eq 'open' || $state eq 'home' || $state eq 'unlocked';
	return MDI_COLOR_INACTIVE;
}

sub _mdiImage {
	my ($icon, $domain, $state) = @_;
	return unless defined $icon && length $icon;

	my ($name) = $icon =~ /^mdi:(.+)$/i;
	return unless defined $name && length $name;

	$name = lc $name;
	$name =~ s/[^a-z0-9-]//g;
	return unless length $name;

	# Skip ImageProxy id if we know the glyph is missing
	return unless Plugins::Assistant::Mdi::hasIcon($name);

	my $color = _mdiStateColor($domain, $state);

	require Slim::Web::ImageProxy;

	my $id = MDI_IMAGE_SCHEME.$name.'/'.$color;
	my $proxyUrl = Slim::Web::ImageProxy::proxiedImage($id, 1);
	main::DEBUGLOG && $log->is_debug && $log->debug('MDI icon: ', $icon, ' color=', $color, ' -> ', $proxyUrl);
	return $proxyUrl;
}

# Id: assistant-mdi:{name} or assistant-mdi:{name}/{rrggbb}
# Sync handler: return file: URL (local render — no network).
sub _mdiImageProxyHandler {
	my ($url, $spec, $cb) = @_;

	my ($name, $color) = $url =~ /^assistant-mdi:([a-z0-9-]+)(?:\/([0-9a-f]{6}))?$/i;
	unless ($name) {
		$log->error('Invalid MDI image proxy id: ', $url // '');
		$cb->(undef) if $cb;
		return undef;
	}
	$name = lc $name;
	$color = lc($color || MDI_COLOR_INACTIVE);
	$color = MDI_COLOR_INACTIVE unless $color =~ /^[0-9a-f]{6}$/;

	my $file = Plugins::Assistant::Mdi::renderPngFile($name, $color);
	unless ($file && -f $file) {
		$log->error('MDI local render failed for ', $name, '/', $color);
		$cb->(undef) if $cb;
		return undef;
	}

	require Slim::Utils::Misc;
	my $fileUrl = Slim::Utils::Misc::fileURLFromPath($file);
	main::DEBUGLOG && $log->is_debug && $log->debug('MDI local: ', $name, '/', $color, ' -> ', $fileUrl);

	# Sync return — ImageProxy will fetch/resize the file: URL
	return $fileUrl;
}

sub _haImageProxyHandler {
	my ($url, $spec, $cb) = @_;

	my ($path) = $url =~ /^assistant-ha:(.*)$/s;
	unless (defined $path && length $path) {
		$cb->(undef) if $cb;
		return undef;
	}

	my $base = $prefs->get('connect') || '';
	my $token = $prefs->get('pass') || '';
	unless ($base) {
		$cb->(undef) if $cb;
		return undef;
	}

	$base =~ s{/$}{};
	$path = '/'.$path unless $path =~ m{^/};
	my $realUrl = $base.$path;

	main::DEBUGLOG && $log->is_debug && $log->debug('HA image proxy fetch: ', $realUrl);

	my %headers = (
		'Accept' => 'image/jpeg,image/png,image/webp,image/*;q=0.8,*/*;q=0.5',
	);
	$headers{Authorization} = 'Bearer '.$token if length $token;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $dataRef = $http->contentRef;
			unless ($dataRef && length($$dataRef)) {
				$cb->(undef) if $cb;
				return;
			}

			my $cacheDir = preferences('server')->get('cachedir') || '/tmp';
			my $tmp = $cacheDir.'/imgproxy_ha_'.md5_hex($realUrl);
			if (open my $fh, '>:raw', $tmp) {
				print $fh $$dataRef;
				close $fh;
				$cb->(Slim::Utils::Misc::fileURLFromPath($tmp)) if $cb;
			}
			else {
				$log->error('Cannot write HA image cache file: ', $tmp);
				$cb->(undef) if $cb;
			}
		},
		sub {
			my ($http, $error) = @_;
			$log->error('HA image fetch failed: ', $error || '', ' url=', $realUrl);
			$cb->(undef) if $cb;
		},
		{
			timeout => 30,
			cache   => 1,
		}
	)->get($realUrl, %headers);

	return undef;
}

1;
