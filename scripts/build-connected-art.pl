#!/usr/bin/perl
# Builds the Connected Art tab data.
#   perl scripts/build-connected-art.pl [era1.json era2.json ...]
# With arguments: merges the given research files (arrays of groups) into
# connected-art.json. Without: re-reads connected-art.json. Either way it
# normalises every group (ids, sizes, connected_to neighbours) and rewrites the
# single `var _CA=...;` line in index.html. Collector data (owned/missing) is
# ticked by the user in the page (not linked to _SD), so it is not stored here.
use strict; use warnings;
use JSON::PP;
use FindBin;
my $root = "$FindBin::Bin/..";
my $json = JSON::PP->new->utf8->canonical;

sub slurp { my $f = shift; open my $fh, '<:raw', $f or die "$f: $!"; local $/; my $s = <$fh>; close $fh; $s }

my @groups;
if (@ARGV) { push @groups, @{ $json->decode(slurp($_)) } for @ARGV }
else       { @groups = @{ $json->decode(slurp("$root/connected-art.json")) } }

my %LAYOUT = map { $_ => 1 } qw(horizontal vertical grid panorama legend vunion multi-panel);
my %ERA = ('WOTC (Neo)' => 'WOTC', 'WOTC / Platinum' => 'WOTC', 'DP' => 'Diamond & Pearl',
           'BW' => 'Black & White', 'SV' => 'Scarlet & Violet', 'ME' => 'Mega Evolution',
           'SWSH' => 'Sword & Shield', 'SM' => 'Sun & Moon');
my (%seen, @out);
for my $g (@groups) {
    my @cards = sort { $a->{position} <=> $b->{position} } @{ $g->{cards} || [] };
    next unless @cards >= 2;
    $g->{layout_type} = 'multi-panel' unless $LAYOUT{ $g->{layout_type} // '' };

    # display_order -> rows of positions
    my $d = $g->{display_order};
    $d = [ map { $_->{position} } @cards ] unless ref $d eq 'ARRAY' && @$d;
    my @rows = ref $d->[0] eq 'ARRAY' ? @$d
             : ($g->{layout_type} =~ /^(vertical|legend)$/) ? (map { [$_] } @$d) : ($d);
    my %at;
    for my $r (0 .. $#rows) { for my $c (0 .. $#{ $rows[$r] }) { $at{"$r,$c"} = $rows[$r][$c] } }
    my %nb;
    for my $k (keys %at) {
        my ($r, $c) = split /,/, $k;
        for my $o ([0,1],[0,-1],[1,0],[-1,0]) {
            my $n = $at{ ($r+$o->[0]) . ',' . ($c+$o->[1]) };
            push @{ $nb{ $at{$k} } }, 0+$n if defined $n;
        }
    }
    for my $c (@cards) {
        $c->{connected_to} = [ sort { $a <=> $b } @{ $nb{ $c->{position} } || [] } ];
        $c->{$_} //= '' for qw(card_name card_number rarity set_name artist language image_url thumbnail_url notes);
        $c->{position} += 0;
    }

    # Keep an existing id stable (owned ticks are keyed on it); only derive one for new groups.
    my $id = $g->{group_id};
    unless (defined $id && length $id) {
        ($id = lc "$g->{group_name} $g->{release_year}") =~ s/[^a-z0-9]+/-/g;
        $id =~ s/^-|-$//g;
    }
    $id .= '-' . ++$seen{$id} if $seen{$id}++;
    $g->{group_id} = $id;
    $g->{cards} = \@cards;
    $g->{group_size} = scalar @cards;
    # One sortable/filterable year; keep any "1999 (JP) / 2009 (EN)" detail separately.
    my $yr = "$g->{release_year}";
    if ($yr =~ /^\D*(\d{4})/ && $yr ne $1) { $g->{release_detail} = $yr; $yr = $1 }
    $g->{release_year} = $yr;
    $g->{era} = $ERA{ $g->{era} // '' } // $g->{era} // '';
    $g->{thumbnail_url} ||= $cards[0]{thumbnail_url};
    $g->{combined_artwork_url} //= '';
    $g->{verification_status} = 'needs_review' unless ($g->{verification_status} // '') eq 'verified';
    $g->{$_} //= '' for qw(group_name era set_name set_code artist group_type language description
                           connection_description hidden_details storytelling collector_significance review_reason);
    $g->{$_} ||= [] for qw(source_references pokemon_featured);
    push @out, $g;
}
@out = sort { $a->{release_year} cmp $b->{release_year} || $a->{group_name} cmp $b->{group_name} } @out;

open my $o, '>:raw', "$root/connected-art.json" or die $!;
print $o JSON::PP->new->utf8->canonical->pretty->encode(\@out);
close $o;

my $html = slurp("$root/index.html");
my $line = 'var _CA=' . $json->encode(\@out) . ';';
$line =~ s{</}{<\\/}g;
$html =~ s/^var _CA=.*;(?=\r?$)/$line/m or die "no `var _CA=` line in index.html\n";
open my $h, '>:raw', "$root/index.html" or die $!;
print $h $html;
close $h;

my $n = 0; $n += $_->{group_size} for @out;
printf "%d groups, %d cards\n", scalar @out, $n;
