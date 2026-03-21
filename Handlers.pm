package Plugins::Assistant::Handlers;

use strict;

our %entities = (
    a => sub {
		my ($data) = @_;
		my @results;
		foreach my $entity (keys %{$data->{a}}) {
			push @results, {
				entity => $entity,
				name => $data->{a}->{$entity}->{a}->{friendly_name} // $entity,
				icon => $data->{a}->{$entity}->{a}->{icon},
				state => $data->{a}->{$entity}->{s}
			}
		}
		return \@results;
	},
    c => sub {
		my ($data) = @_;
		my @results;
		foreach my $entity (keys %{$data->{c}}) {
			push @results, {
				entity => $entity,
				state => $data->{c}->{$entity}->{'+'}->{s}
			}
		}
		return \@results;
	}
);

our %service = (
    light => sub {
        my ($state) = @_;
        my $results = $state eq 'off' ? 'turn_on' : 'turn_off';
        return $results;
    },
    switch => sub {
        my ($state) = @_;
        my $results = $state eq 'off' ? 'turn_on' : 'turn_off';
        return $results;
    },
    cover => sub {
        my ($state) = @_;
        my $results = $state eq 'open' ? 'close_cover' : 'open_cover';
        return $results;
    }
);

1;
