package Plugins::Assistant::Handlers;

use strict;

our %entities = (
	a => sub {
		my ($data) = @_;
		my @results;
		foreach my $entity (keys %{$data->{a} || {}}) {
			my $attrs = $data->{a}->{$entity}->{a} || {};
			push @results, {
				entity         => $entity,
				name           => $attrs->{friendly_name} // $entity,
				icon           => $attrs->{icon},
				entity_picture => $attrs->{entity_picture},
				state          => $data->{a}->{$entity}->{s},
			};
		}
		return \@results;
	},
	c => sub {
		my ($data) = @_;
		my @results;
		foreach my $entity (keys %{$data->{c} || {}}) {
			my $change = $data->{c}->{$entity}->{'+'} || {};
			my $update = {
				entity => $entity,
			};
			$update->{state} = $change->{s} if exists $change->{s};
			if (exists $change->{a}) {
				$update->{name} = $change->{a}->{friendly_name} if exists $change->{a}->{friendly_name};
				$update->{icon} = $change->{a}->{icon} if exists $change->{a}->{icon};
				$update->{entity_picture} = $change->{a}->{entity_picture}
					if exists $change->{a}->{entity_picture};
			}
			# Attribute removals (e.g. entity_picture cleared)
			if (my $removed = $data->{c}->{$entity}->{'-'}) {
				if (ref $removed->{a} eq 'ARRAY') {
					foreach my $key (@{$removed->{a}}) {
						$update->{entity_picture} = undef if $key eq 'entity_picture';
						$update->{icon} = undef if $key eq 'icon';
					}
				}
			}
			push @results, $update;
		}
		return \@results;
	},
	r => sub {
		my ($data) = @_;
		my @results;
		my $removed = $data->{r} || [];
		$removed = [$removed] unless ref $removed eq 'ARRAY';
		foreach my $entity (@$removed) {
			push @results, {
				entity  => $entity,
				removed => 1,
			};
		}
		return \@results;
	},
);

our %service = (
	light => sub {
		my ($state) = @_;
		return ($state && $state eq 'off') ? 'turn_on' : 'turn_off';
	},
	switch => sub {
		my ($state) = @_;
		return ($state && $state eq 'off') ? 'turn_on' : 'turn_off';
	},
	cover => sub {
		my ($state) = @_;
		# Treat opening as open, closing as closed for the next action
		return 'close_cover' if $state && ($state eq 'open' || $state eq 'opening');
		return 'open_cover';
	},
);

1;
