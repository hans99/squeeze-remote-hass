package Plugins::Assistant::Mdi;

# Offline Material Design Icons: bundled path data + local SVG-path → PNG rasterizer.
# No iconify.design / wsrv.nl. Optional system rsvg-convert / ImageMagick if present.

use strict;

use Digest::MD5 qw(md5_hex);
use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

# Avoid Compress::Zlib — LMS ships conflicting IO::Compress versions.

use constant VIEWBOX   => 24;
use constant PNG_SIZE  => 128;
use constant CURVE_STEPS => 8;

my $log = logger('plugin.assistant');

my $paths;          # name => SVG path d=
my $pathsLoaded = 0;
my $extConverter;   # cached 'rsvg-convert' | 'magick' | 'convert' | ''

sub renderPngFile {
	my ($name, $color) = @_;

	$name = lc($name // '');
	$name =~ s/[^a-z0-9-]//g;
	$color = lc($color // '44739e');
	$color = '44739e' unless $color =~ /^[0-9a-f]{6}$/;
	return unless length $name;

	my $cacheDir = preferences('server')->get('cachedir') || '/tmp';
	my $cacheKey = $name.'_'.$color.'_'.PNG_SIZE;
	my $outFile  = catfile($cacheDir, 'imgproxy_mdi_'.md5_hex($cacheKey).'.png');

	return $outFile if -f $outFile && -s $outFile;

	my $d = _pathFor($name);
	unless (defined $d && length $d) {
		main::DEBUGLOG && $log->is_debug && $log->debug("MDI path not found: $name");
		return;
	}

	my $png;
	if (my $conv = _externalConverter()) {
		$png = _renderViaExternal($d, $color, $conv);
	}
	$png ||= _renderViaPerl($d, $color);

	unless ($png && length $png) {
		$log->error("MDI render failed for $name/$color");
		return;
	}

	if (open my $fh, '>:raw', $outFile) {
		print $fh $png;
		close $fh;
		return $outFile;
	}

	$log->error("Cannot write MDI cache: $outFile");
	return;
}

sub hasIcon {
	my ($name) = @_;
	$name = lc($name // '');
	$name =~ s/[^a-z0-9-]//g;
	return 0 unless length $name;
	return defined _pathFor($name) ? 1 : 0;
}

# --- path database -----------------------------------------------------------

sub _pathFor {
	my ($name) = @_;
	_loadPaths() unless $pathsLoaded;
	return unless $paths;
	return $paths->{$name};
}

sub _loadPaths {
	$pathsLoaded = 1;
	my $file = catfile(dirname(__FILE__), 'share', 'mdi-paths.json');
	unless (-f $file) {
		$log->error("MDI path database missing: $file");
		return;
	}

	my $json;
	if (open my $fh, '<:raw', $file) {
		local $/;
		$json = <$fh>;
		close $fh;
	}
	else {
		$log->error("Cannot read MDI path database: $file");
		return;
	}

	my $data = eval { decode_json($json) };
	if (!$data || ref $data ne 'HASH') {
		$log->error('Failed to decode MDI paths JSON: ', $@ || '');
		return;
	}

	$paths = $data;
	main::INFOLOG && $log->is_info && $log->info('Loaded ', scalar(keys %$paths), ' MDI icon paths');
}

# --- optional external SVG→PNG ----------------------------------------------

sub _externalConverter {
	return $extConverter if defined $extConverter;

	$extConverter = '';
	for my $bin (qw(rsvg-convert magick convert)) {
		my $which = _which($bin);
		if ($which) {
			$extConverter = $bin;
			last;
		}
	}
	return $extConverter;
}

sub _which {
	my ($bin) = @_;
	for my $dir (split /:/, ($ENV{PATH} || '')) {
		my $p = catfile($dir, $bin);
		return $p if -x $p;
	}
	return;
}

sub _renderViaExternal {
	my ($d, $color, $conv) = @_;

	my $svg = _svgDocument($d, $color);
	my $cacheDir = preferences('server')->get('cachedir') || '/tmp';
	my $svgFile = catfile($cacheDir, 'mdi_tmp_'.$$.'_'.int(rand(1e9)).'.svg');
	my $pngFile = $svgFile;
	$pngFile =~ s/\.svg$/.png/;

	my $ok;
	eval {
		open my $fh, '>:encoding(UTF-8)', $svgFile or die $!;
		print $fh $svg;
		close $fh;

		my @cmd;
		if ($conv eq 'rsvg-convert') {
			@cmd = ($conv, '-w', PNG_SIZE, '-h', PNG_SIZE, '-o', $pngFile, $svgFile);
		}
		elsif ($conv eq 'magick') {
			@cmd = ($conv, $svgFile, '-resize', PNG_SIZE.'x'.PNG_SIZE, $pngFile);
		}
		else {
			@cmd = ($conv, $svgFile, '-resize', PNG_SIZE.'x'.PNG_SIZE, $pngFile);
		}

		my $rc = system(@cmd);
		die "exit $rc" if $rc;

		open my $in, '<:raw', $pngFile or die $!;
		local $/;
		$ok = <$in>;
		close $in;
		1;
	} or do {
		main::DEBUGLOG && $log->is_debug && $log->debug('External MDI convert failed: ', $@ || '');
		$ok = undef;
	};

	unlink $svgFile if -f $svgFile;
	unlink $pngFile if -f $pngFile;
	return $ok;
}

sub _svgDocument {
	my ($d, $color) = @_;
	return sprintf(
		q{<?xml version="1.0" encoding="UTF-8"?>} .
		q{<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">} .
		q{<path fill="#%s" d="%s"/></svg>},
		PNG_SIZE, PNG_SIZE, VIEWBOX, VIEWBOX, $color, $d
	);
}

# --- pure-Perl path → PNG ---------------------------------------------------

sub _renderViaPerl {
	my ($d, $colorHex) = @_;

	my ($r, $g, $b) = map { hex($_) } ($colorHex =~ /(..)(..)(..)/);
	my $size = PNG_SIZE;
	my $scale = $size / VIEWBOX;

	my @polys = _pathToPolygons($d);
	return unless @polys;

	# RGBA coverage mask — even-odd across all subpaths so holes punch through
	my $px = $size * $size;
	my @a = (0) x $px;
	_fillEvenOdd(\@a, $size, \@polys, $scale);

	# Build raw RGBA
	my $raw = '';
	for my $i (0 .. $px - 1) {
		if ($a[$i]) {
			$raw .= pack('CCCC', $r, $g, $b, 255);
		}
		else {
			$raw .= pack('CCCC', 0, 0, 0, 0);
		}
	}

	return _encodePng($size, $size, $raw);
}

sub _pathToPolygons {
	my ($d) = @_;

	my @tokens = $d =~ /([MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)/g;
	return () unless @tokens;

	my @polys;
	my @curr;
	my ($x, $y) = (0, 0);
	my ($sx, $sy) = (0, 0);       # subpath start
	my ($lx, $ly) = (0, 0);       # last control for smooth curves
	my $lastCmd = '';

	my $i = 0;
	while ($i < @tokens) {
		my $t = $tokens[$i];
		if ($t =~ /^[A-Za-z]$/) {
			my $cmd = $t;
			$i++;
			my $rel = ($cmd eq lc $cmd) && ($cmd ne 'z' && $cmd ne 'Z');
			$cmd = uc $cmd;

			my $need = _cmdArity($cmd);
			if ($cmd eq 'Z') {
				if (@curr >= 2) {
					push @curr, [$sx, $sy] unless _near($curr[-1][0], $sx) && _near($curr[-1][1], $sy);
					push @polys, [@curr];
				}
				@curr = ();
				($x, $y) = ($sx, $sy);
				$lastCmd = 'Z';
				next;
			}

			while ($i + $need - 1 < @tokens && $tokens[$i] !~ /^[A-Za-z]$/) {
				my @n = @tokens[$i .. $i + $need - 1];
				$i += $need;
				# Convert string nums
				@n = map { 0 + $_ } @n;

				if ($cmd eq 'M') {
					if (@curr >= 2) {
						push @polys, [@curr];
					}
					@curr = ();
					if ($rel) { $x += $n[0]; $y += $n[1]; }
					else      { ($x, $y) = @n[0, 1]; }
					($sx, $sy) = ($x, $y);
					push @curr, [$x, $y];
					# Subsequent pairs are implicit L
					$cmd = 'L';
					$need = 2;
					$lastCmd = 'M';
					($lx, $ly) = ($x, $y);
					next;
				}

				if ($cmd eq 'L') {
					if ($rel) { $x += $n[0]; $y += $n[1]; }
					else      { ($x, $y) = @n[0, 1]; }
					push @curr, [$x, $y];
					($lx, $ly) = ($x, $y);
				}
				elsif ($cmd eq 'H') {
					$x = $rel ? $x + $n[0] : $n[0];
					push @curr, [$x, $y];
					($lx, $ly) = ($x, $y);
				}
				elsif ($cmd eq 'V') {
					$y = $rel ? $y + $n[0] : $n[0];
					push @curr, [$x, $y];
					($lx, $ly) = ($x, $y);
				}
				elsif ($cmd eq 'C') {
					my ($x1, $y1, $x2, $y2, $x3, $y3) = @n;
					if ($rel) {
						$x1 += $x; $y1 += $y;
						$x2 += $x; $y2 += $y;
						$x3 += $x; $y3 += $y;
					}
					_appendCubic(\@curr, $x, $y, $x1, $y1, $x2, $y2, $x3, $y3);
					($lx, $ly) = ($x2, $y2);
					($x, $y) = ($x3, $y3);
				}
				elsif ($cmd eq 'S') {
					my ($x2, $y2, $x3, $y3) = @n;
					my ($x1, $y1);
					if ($lastCmd eq 'C' || $lastCmd eq 'S') {
						$x1 = 2 * $x - $lx;
						$y1 = 2 * $y - $ly;
					}
					else {
						($x1, $y1) = ($x, $y);
					}
					if ($rel) {
						$x2 += $x; $y2 += $y;
						$x3 += $x; $y3 += $y;
					}
					_appendCubic(\@curr, $x, $y, $x1, $y1, $x2, $y2, $x3, $y3);
					($lx, $ly) = ($x2, $y2);
					($x, $y) = ($x3, $y3);
				}
				elsif ($cmd eq 'Q') {
					my ($x1, $y1, $x2, $y2) = @n;
					if ($rel) {
						$x1 += $x; $y1 += $y;
						$x2 += $x; $y2 += $y;
					}
					# Elevate quadratic to cubic
					my $cx1 = $x + 2/3 * ($x1 - $x);
					my $cy1 = $y + 2/3 * ($y1 - $y);
					my $cx2 = $x2 + 2/3 * ($x1 - $x2);
					my $cy2 = $y2 + 2/3 * ($y1 - $y2);
					_appendCubic(\@curr, $x, $y, $cx1, $cy1, $cx2, $cy2, $x2, $y2);
					($lx, $ly) = ($x1, $y1);
					($x, $y) = ($x2, $y2);
				}
				elsif ($cmd eq 'T') {
					my ($x2, $y2) = @n;
					my ($x1, $y1);
					if ($lastCmd eq 'Q' || $lastCmd eq 'T') {
						$x1 = 2 * $x - $lx;
						$y1 = 2 * $y - $ly;
					}
					else {
						($x1, $y1) = ($x, $y);
					}
					if ($rel) { $x2 += $x; $y2 += $y; }
					my $cx1 = $x + 2/3 * ($x1 - $x);
					my $cy1 = $y + 2/3 * ($y1 - $y);
					my $cx2 = $x2 + 2/3 * ($x1 - $x2);
					my $cy2 = $y2 + 2/3 * ($y1 - $y2);
					_appendCubic(\@curr, $x, $y, $cx1, $cy1, $cx2, $cy2, $x2, $y2);
					($lx, $ly) = ($x1, $y1);
					($x, $y) = ($x2, $y2);
				}
				elsif ($cmd eq 'A') {
					my ($rx, $ry, $rot, $la, $sw, $x2, $y2) = @n;
					if ($rel) { $x2 += $x; $y2 += $y; }
					_appendArc(\@curr, $x, $y, $rx, $ry, $rot, $la, $sw, $x2, $y2);
					($x, $y) = ($x2, $y2);
					($lx, $ly) = ($x, $y);
				}

				$lastCmd = $cmd;
				# After first M pair, remaining are L — already switched
			}
		}
		else {
			# Orphan number — skip
			$i++;
		}
	}

	push @polys, [@curr] if @curr >= 2;
	return @polys;
}

sub _cmdArity {
	my ($cmd) = @_;
	return 2 if $cmd =~ /^[MLT]$/;
	return 1 if $cmd =~ /^[HV]$/;
	return 6 if $cmd eq 'C';
	return 4 if $cmd =~ /^[SQ]$/;
	return 7 if $cmd eq 'A';
	return 0;
}

sub _near {
	my ($a, $b) = @_;
	return abs($a - $b) < 1e-6;
}

sub _appendCubic {
	my ($pts, $x0, $y0, $x1, $y1, $x2, $y2, $x3, $y3) = @_;
	for my $s (1 .. CURVE_STEPS) {
		my $t = $s / CURVE_STEPS;
		my $u = 1 - $t;
		my $x = $u*$u*$u*$x0 + 3*$u*$u*$t*$x1 + 3*$u*$t*$t*$x2 + $t*$t*$t*$x3;
		my $y = $u*$u*$u*$y0 + 3*$u*$u*$t*$y1 + 3*$u*$t*$t*$y2 + $t*$t*$t*$y3;
		push @$pts, [$x, $y];
	}
}

# SVG elliptical arc → polyline (endpoint parameterization)
sub _appendArc {
	my ($pts, $x1, $y1, $rx, $ry, $phiDeg, $large, $sweep, $x2, $y2) = @_;

	$rx = abs($rx);
	$ry = abs($ry);
	if ($rx < 1e-6 || $ry < 1e-6 || (_near($x1, $x2) && _near($y1, $y2))) {
		push @$pts, [$x2, $y2];
		return;
	}

	my $phi = $phiDeg * 3.141592653589793 / 180;
	my $cosphi = cos($phi);
	my $sinphi = sin($phi);

	my $dx = ($x1 - $x2) / 2;
	my $dy = ($y1 - $y2) / 2;
	my $x1p =  $cosphi * $dx + $sinphi * $dy;
	my $y1p = -$sinphi * $dx + $cosphi * $dy;

	my $lambda = ($x1p*$x1p)/($rx*$rx) + ($y1p*$y1p)/($ry*$ry);
	if ($lambda > 1) {
		my $s = sqrt($lambda);
		$rx *= $s;
		$ry *= $s;
	}

	my $rxsq = $rx*$rx;
	my $rysq = $ry*$ry;
	my $x1psq = $x1p*$x1p;
	my $y1psq = $y1p*$y1p;

	my $num = $rxsq*$rysq - $rxsq*$y1psq - $rysq*$x1psq;
	my $den = $rxsq*$y1psq + $rysq*$x1psq;
	my $c = ($den > 0 && $num > 0) ? sqrt($num / $den) : 0;
	$c = -$c if $large == $sweep;

	my $cxp =  $c * $rx * $y1p / $ry;
	my $cyp = -$c * $ry * $x1p / $rx;

	my $cx = $cosphi * $cxp - $sinphi * $cyp + ($x1 + $x2) / 2;
	my $cy = $sinphi * $cxp + $cosphi * $cyp + ($y1 + $y2) / 2;

	my $ux = ($x1p - $cxp) / $rx;
	my $uy = ($y1p - $cyp) / $ry;
	my $vx = (-$x1p - $cxp) / $rx;
	my $vy = (-$y1p - $cyp) / $ry;

	my $theta1 = _vectorAngle(1, 0, $ux, $uy);
	my $dtheta = _vectorAngle($ux, $uy, $vx, $vy);
	if (!$sweep && $dtheta > 0) { $dtheta -= 2 * 3.141592653589793; }
	if ($sweep && $dtheta < 0) { $dtheta += 2 * 3.141592653589793; }

	my $steps = int(abs($dtheta) / (3.141592653589793 / 8)) + 1;
	$steps = 2 if $steps < 2;
	$steps = 24 if $steps > 24;

	for my $s (1 .. $steps) {
		my $t = $theta1 + $dtheta * ($s / $steps);
		my $xp = $rx * cos($t);
		my $yp = $ry * sin($t);
		my $x = $cosphi * $xp - $sinphi * $yp + $cx;
		my $y = $sinphi * $xp + $cosphi * $yp + $cy;
		push @$pts, [$x, $y];
	}
}

sub _vectorAngle {
	my ($ux, $uy, $vx, $vy) = @_;
	my $dot = $ux*$vx + $uy*$vy;
	my $ulen = sqrt($ux*$ux + $uy*$uy) || 1e-12;
	my $vlen = sqrt($vx*$vx + $vy*$vy) || 1e-12;
	my $c = $dot / ($ulen * $vlen);
	$c = 1 if $c > 1;
	$c = -1 if $c < -1;
	my $ang = atan2(sqrt(1 - $c*$c), $c);
	$ang = -$ang if $ux*$vy - $uy*$vx < 0;
	return $ang;
}

# Even-odd scanline fill for all subpaths (viewBox coords scaled to pixels)
sub _fillEvenOdd {
	my ($buf, $size, $polys, $scale) = @_;

	my @edges;
	my ($minY, $maxY) = ($size, -1);

	for my $poly (@$polys) {
		next unless $poly && @$poly >= 3;
		my @pts = map { [ $_->[0] * $scale, $_->[1] * $scale ] } @$poly;
		my $n = scalar @pts;
		for my $i (0 .. $n - 1) {
			my ($x0, $y0) = @{$pts[$i]};
			my ($x1, $y1) = @{$pts[($i + 1) % $n]};
			push @edges, [$x0, $y0, $x1, $y1];
			$minY = int($y0) if $y0 < $minY;
			$maxY = int($y0) if $y0 > $maxY;
			$minY = int($y1) if $y1 < $minY;
			$maxY = int($y1) if $y1 > $maxY;
		}
	}

	$minY = 0 if $minY < 0;
	$maxY = $size - 1 if $maxY >= $size;
	return if $maxY < $minY || !@edges;

	for my $y ($minY .. $maxY) {
		my $yy = $y + 0.5;
		my @xs;
		for my $e (@edges) {
			my ($x0, $y0, $x1, $y1) = @$e;
			next if ($y0 <= $yy && $y1 <= $yy) || ($y0 > $yy && $y1 > $yy);
			next if abs($y1 - $y0) < 1e-9;
			my $t = ($yy - $y0) / ($y1 - $y0);
			push @xs, $x0 + $t * ($x1 - $x0);
		}
		@xs = sort { $a <=> $b } @xs;
		for (my $k = 0; $k + 1 < @xs; $k += 2) {
			my $xStart = int($xs[$k] + 0.5);
			my $xEnd   = int($xs[$k + 1] + 0.5);
			$xStart = 0 if $xStart < 0;
			$xEnd = $size - 1 if $xEnd >= $size;
			for my $x ($xStart .. $xEnd) {
				$buf->[ $y * $size + $x ] = 1;
			}
		}
	}
}

sub _encodePng {
	my ($w, $h, $rgba) = @_;

	my $raw = '';
	for my $y (0 .. $h - 1) {
		$raw .= "\x00";  # filter None
		$raw .= substr($rgba, $y * $w * 4, $w * 4);
	}

	# Stored (uncompressed) zlib — no Compress::Zlib dependency
	my $zlib = _zlibStore($raw);
	return unless defined $zlib;

	my $ihdr = pack('NNCCCCC', $w, $h, 8, 6, 0, 0, 0);  # 8-bit RGBA
	my $png = "\x89PNG\r\n\x1a\n";
	$png .= _pngChunk('IHDR', $ihdr);
	$png .= _pngChunk('IDAT', $zlib);
	$png .= _pngChunk('IEND', '');
	return $png;
}

sub _pngChunk {
	my ($type, $data) = @_;
	my $len = pack('N', length($data));
	my $crc = _crc32($type . $data);
	return $len . $type . $data . pack('N', $crc);
}

# zlib wrapper around deflate "stored" blocks (BTYPE=00), max 65535 bytes each
sub _zlibStore {
	my ($data) = @_;
	my $out = pack('CC', 0x78, 0x01);  # CMF/FLG — deflate, no dict, check bits

	my $offset = 0;
	my $len = length($data);
	while ($offset < $len) {
		my $chunkLen = $len - $offset;
		$chunkLen = 65535 if $chunkLen > 65535;
		my $final = ($offset + $chunkLen >= $len) ? 1 : 0;
		my $chunk = substr($data, $offset, $chunkLen);
		$out .= pack('C', $final);                    # BFINAL + BTYPE=00
		$out .= pack('v', $chunkLen);                 # LEN
		$out .= pack('v', $chunkLen ^ 0xFFFF);        # NLEN
		$out .= $chunk;
		$offset += $chunkLen;
	}

	$out .= pack('N', _adler32($data));
	return $out;
}

sub _adler32 {
	my ($data) = @_;
	my ($a, $b) = (1, 0);
	my $len = length($data);
	for (my $i = 0; $i < $len; $i++) {
		$a = ($a + ord(substr($data, $i, 1))) % 65521;
		$b = ($b + $a) % 65521;
	}
	return (($b << 16) | $a) & 0xFFFFFFFF;
}

{
	my @crc_table;
	sub _crc32 {
		my ($data) = @_;
		unless (@crc_table) {
			for my $n (0 .. 255) {
				my $c = $n;
				for (1 .. 8) {
					$c = ($c & 1) ? (0xEDB88320 ^ ($c >> 1)) : ($c >> 1);
				}
				$crc_table[$n] = $c;
			}
		}
		my $crc = 0xFFFFFFFF;
		my $len = length($data);
		for (my $i = 0; $i < $len; $i++) {
			$crc = $crc_table[($crc ^ ord(substr($data, $i, 1))) & 0xFF] ^ ($crc >> 8);
		}
		return ($crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
	}
}

1;
