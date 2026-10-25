#!/usr/bin/perl
# Builds the Energy Cards tab data.
#   sh scripts/fetch-energy.sh <raw-dir>      (downloads TCGdex + pokemontcg.io)
#   perl scripts/build-energy.pl <raw-dir>
# Merges every English energy card (basic and special) into normalized tables,
# writes energy-cards.json and rewrites the single `var _EN=...;` line in
# index.html. Each card is split into one row per print variant (reverse holo,
# cosmos, league/staff stamps, Worlds decks, 1st edition, ...) from TCGdex's
# variants_detailed. Ownership/favourites/notes live in the page (localStorage).
use strict; use warnings; use utf8;
use JSON::PP;
use FindBin;
my $root = "$FindBin::Bin/..";
my $raw = shift or die "usage: build-energy.pl <raw-dir>\n";
my $json = JSON::PP->new->utf8->canonical;

sub slurp { my $f = shift; open my $fh, '<:raw', $f or die "$f: $!"; local $/; my $s = <$fh>; close $fh; $s }
sub jread { my $f = shift; -s $f ? eval { $json->decode(slurp($f)) } : undef }
sub nnum  { my $n = shift // ''; $n =~ s/^0+(?=\w)//; lc $n }

# ── Lookup tables ─────────────────────────────────────────────
my @TYPES = (
  ['grass','Grass','#5cb85c'], ['fire','Fire','#e8562a'], ['water','Water','#3b8fd9'],
  ['lightning','Lightning','#f5c518'], ['psychic','Psychic','#a05cc9'], ['fighting','Fighting','#c0703a'],
  ['darkness','Darkness','#4a5868'], ['metal','Metal','#8a9aa6'], ['fairy','Fairy','#e889c0'],
  ['dragon','Dragon','#c9a227'], ['colorless','Colorless','#c8c8c8'], ['multi','Multi-type','#ff6fb5'],
);
my %TIDX = map { $TYPES[$_][0] => $_ } 0 .. $#TYPES;

my @ERAS = ('Wizards of the Coast','e-Card / e-Reader','EX','POP Series','Diamond & Pearl / Platinum',
  'HeartGold SoulSilver','Black & White','XY','Sun & Moon','Sword & Shield','Scarlet & Violet','Mega Evolution');
my %EIDX = map { $ERAS[$_] => $_ } 0 .. $#ERAS;
my %SERIE_ERA = (base=>0,gym=>0,neo=>0,lc=>0,PMCG=>0,VS=>0,ecard=>1,ex=>2,pop=>3,dp=>4,pl=>4,DP=>4,DPt=>4,
  hgss=>5,col=>5,HS=>5,bw=>6,BW=>6,xy=>7,XY=>7,sm=>8,SM=>8,swsh=>9,S=>9,sv=>10,SV=>10,me=>11,M=>11);
my %TK_ERA = (EX=>2, DP=>4, HS=>5, BW=>6, XY=>7, SM=>8);

my %PTCG_SET = (base6=>'lc', rsv10pt5=>'sv10.5w', zsv10pt5=>'sv10.5b', tk1a=>'tk-ex-latia', tk1b=>'tk-ex-latio',
  tk2a=>'tk-ex-p', tk2b=>'tk-ex-m', sm35=>'sm3.5');
sub ptcg2dex {
  my $id = shift;
  return $PTCG_SET{$id} if $PTCG_SET{$id};
  $id =~ s/pt5$/.5/;
  $id =~ s/^(sv|me)(\d)(?=\.5$|$)/sprintf('%s%02d',$1,$2)/e;
  $id;
}

my %STAMP = ('1st-edition'=>'1st Edition','set-logo'=>'Set-logo stamp','player-rewards-program'=>'League stamp (Play! Pokémon)',
  'professor-program'=>'Professor Program (staff) stamp','winner'=>'Winner stamp','pokeball'=>'Poké Ball stamp',
  'poke-ball-league'=>'Poké Ball League stamp','charmander'=>'Charmander stamp','squirtle'=>'Squirtle stamp',
  'bulbasaur'=>'Bulbasaur stamp','pikachu'=>'Pikachu stamp');
my %FOIL = (cosmos=>'Cosmos holo',gold=>'Gold foil',pokeball=>'Poké Ball pattern','masterball'=>'Master Ball pattern',
  'cracked-ice'=>'Cracked ice holo',tinsel=>'Tinsel holo',league=>'League holo',energy=>'Energy-symbol pattern');
my %SUBTYPE = (shadowless=>'Shadowless',unlimited=>'Unlimited','1999-2000-copyright'=>'1999-2000 copyright',
  'no-rarity'=>'No rarity symbol','no-e-reader'=>'No e-Reader strip','blue-border'=>'Blue border');
sub tc { join ' ', map { ucfirst } split /-/, shift }

# ── Normalized tables ─────────────────────────────────────────
my (@sets, %setIdx, @products, %prodIdx, @cards, @images, @variants, @market);
sub product { my $p = shift; $prodIdx{$p} //= do { push @products, $p; $#products } }

sub era_for {
  my ($lang, $set) = @_;
  my $s = $set->{serie}{id} // '';
  return $TK_ERA{$1} if $s eq 'tk' && ($set->{name} // '') =~ /^(EX|DP|HS|BW|XY|SM)/;
  $SERIE_ERA{$s} // do { warn "no era for $lang/$set->{id} ($s)\n"; 10 };
}

sub set_row {
  my ($lang, $sid) = @_;
  my $key = "$lang|$sid";
  return $setIdx{$key} if defined $setIdx{$key};
  my $s = jread("$raw/sets_$lang/$sid.json") || { id => $sid, name => $sid };
  my $sym = $s->{symbol} ? "$s->{symbol}.webp" : '';
  push @sets, { id => $sid, name => $s->{name}, lang => uc $lang, era => era_for($lang, $s),
    date => $s->{releaseDate} // '', symbol => $sym, logo => ($s->{logo} ? "$s->{logo}.webp" : ''),
    official => $s->{cardCount}{official} // 0, serie => $s->{serie}{id} // '' };
  $setIdx{$key} = $#sets;
}

sub energy_type {
  my ($name, $effect, $basic) = @_;
  my $t = "$name";
  return 'multi' if $t =~ /Blend|Unit Energy|Holon Energy|Rainbow|Prism|Multi Energy|Aurora|Luminous|Dark Metal/;
  return 'colorless' if $t =~ /Colorless/;
  for my $T (@TYPES) {
    next if $T->[0] =~ /colorless|multi/;
    my $en = $T->[1];
    return $T->[0] if $t =~ /\b$en\b/ || ($T->[0] eq 'darkness' && $t =~ /\bDark\b/);
  }
  my $e = $effect // '';
  return 'multi' if $e =~ /every type|any type|all types/i;
  'colorless';
}

sub tags_for {
  my ($set, $card, $v) = @_;
  my @t;
  my $r = $card->{rarity} // '';
  push @t, 'Reverse holo' if $v->{type} eq 'reverse';
  push @t, 'Holo' if $v->{type} eq 'holo';
  my $foil = $v->{foil} // '';
  push @t, 'Cosmos holo' if $foil eq 'cosmos';
  push @t, 'Gold' if $foil eq 'gold' || $r =~ /Hyper rare|Mega Hyper/i;
  push @t, 'Secret rare' if $r =~ /Secret|Hyper|Mega Hyper/i;
  push @t, 'Full-art / textured' if $r =~ /Ultra|Secret|Hyper/i && $set->{era} >= 8;
  push @t, 'Poké Ball / Master Ball' if $foil =~ /ball/;
  my @st = @{ $v->{stamp} || [] };
  my %s = map { $_ => 1 } @st;
  push @t, 'League promo' if $s{'player-rewards-program'} || $s{'poke-ball-league'} || $foil eq 'league';
  push @t, 'Staff' if $s{'professor-program'};
  push @t, 'Championship / tournament' if $s{winner};
  push @t, 'World Championship deck' if grep { !$STAMP{$_} } @st;
  push @t, '1st Edition' if $s{'1st-edition'};
  push @t, 'Shadowless' if ($v->{subtype} // '') eq 'shadowless';
  push @t, 'e-Reader' if $set->{era} == 1;
  push @t, 'Promo' if $r =~ /Promo/i || $set->{id} =~ /-P$/;
  push @t, 'Jumbo' if ($v->{size} // '') eq 'jumbo';
  push @t, 'Trainer Kit' if $set->{serie} eq 'tk';
  push @t, 'Unique artwork' if $card->{basic} == 0;
  @t;
}

sub variant_label {
  my $v = shift;
  my @p;
  push @p, 'Jumbo' if ($v->{size} // '') eq 'jumbo';
  push @p, $SUBTYPE{$v->{subtype}} // tc($v->{subtype}) if $v->{subtype};
  push @p, $FOIL{$v->{foil}} // tc($v->{foil}) if $v->{foil};
  push @p, $v->{type} eq 'reverse' ? 'Reverse holo' : $v->{type} eq 'holo' ? 'Holo' : 'Normal'
    unless $v->{foil} && $v->{type} ne 'normal';
  for my $s (@{ $v->{stamp} || [] }) {
    push @p, $STAMP{$s} // ('Worlds deck: ' . tc($s));
  }
  join ' · ', @p;
}

sub variant_product {
  my ($set, $v, $base) = @_;
  my %s = map { $_ => 1 } @{ $v->{stamp} || [] };
  return 'World Championships deck' if grep { !$STAMP{$_} } keys %s;
  return 'Play! Pokémon League' if $s{'player-rewards-program'} || $s{'poke-ball-league'};
  return 'Professor Program (staff)' if $s{'professor-program'};
  return 'Tournament prize' if $s{winner};
  return 'Jumbo promo' if ($v->{size} // '') eq 'jumbo';
  $base;
}

sub base_product {
  my ($set, $card) = @_;
  return 'Trainer Kit' if $set->{serie} eq 'tk';
  return 'Energy insert (ETBs, decks, bundles)' if $set->{id} =~ /^(sve|mee)$/;
  return 'My First Battle' if $set->{id} eq 'mfb';
  return 'Promo' if $set->{id} =~ /-P$/ || ($card->{rarity} // '') =~ /Promo/;
  return 'Theme deck / product exclusive' if ($card->{rarity} // '') =~ /^None$/ && $set->{era} >= 6;
  'Booster pack';
}

# ── pokemontcg.io index (TCGplayer USD prices + images) ───────
my (%ptcg, %ptcgUsed);
for my $f (sort glob "$raw/pa*.json") {
  my $d = jread($f) or next;
  for my $c (@{ $d->{data} }) { $ptcg{ ptcg2dex($c->{set}{id}) . '|' . nnum($c->{number}) } = $c }
}

sub usd_for {
  my ($pc, $v) = @_;
  return undef unless $pc && $pc->{tcgplayer} && $pc->{tcgplayer}{prices};
  return undef if @{ $v->{stamp} || [] } && !grep { $_ eq '1st-edition' } @{ $v->{stamp} };
  return undef if $v->{foil} && $v->{foil} !~ /^(gold)$/;
  my $p = $pc->{tcgplayer}{prices};
  my $first = grep { $_ eq '1st-edition' } @{ $v->{stamp} || [] };
  my @k = $first ? ('1stEditionHolofoil','1stEditionNormal')
        : $v->{type} eq 'reverse' ? ('reverseHolofoil')
        : $v->{type} eq 'holo' ? ('holofoil','normal') : ('normal','holofoil','unlimitedNormal','unlimitedHolofoil');
  for (@k) { return $p->{$_}{market} if $p->{$_} && $p->{$_}{market} }
  undef;
}

sub eur_for {
  my $v = shift;
  my $cm = $v->{pricing} && $v->{pricing}{cardmarket} or return undef;
  my @k = $v->{type} eq 'normal' ? qw(trend avg30 avg) : qw(trend-holo avg30-holo avg-holo trend avg30);
  for (@k) { return $cm->{$_} if $cm->{$_} && $cm->{$_} > 0 }
  undef;
}

# ── Cards ─────────────────────────────────────────────────────
my $SCRYDEX = qr/^(sve|mee)$/;   # TCGdex has no art for these; Scrydex does (checked: not the card-back)
for my $lang (qw(en)) {   # English only (user choice, 2026-10-25)
  for my $f (sort glob "$raw/$lang/*.json") {
    my $c = jread($f) or next;
    next unless ($c->{category} // '') eq 'Energy';
    my $si = set_row($lang, $c->{set}{id});
    my $set = $sets[$si];
    my $basic = ($c->{energyType} // '') eq 'Normal' ? 1 : 0;
    # TCGdex flags some special energies (e.g. Shadowy Darkness Energy) as Normal: a basic must also have a plain basic name
    my $plain = $c->{name} =~ /^(Basic )?(Grass|Fire|Water|Lightning|Psychic|Fighting|Darkness|Metal|Fairy) Energy$/;
    $basic = $plain ? ($basic || !$c->{energyType} ? 1 : 0) : 0;
    my $pc = $ptcg{"$set->{id}|" . nnum($c->{localId})};
    $ptcgUsed{"$set->{id}|" . nnum($c->{localId})} = 1 if $pc;
    my $rar = $c->{rarity} // '';
    $rar = $pc->{rarity} if (!$rar || $rar =~ /^none$/i) && $pc && $pc->{rarity};
    $rar = 'None' if !$rar || $rar =~ /^none$/i;
    my $card = { set => $si, num => $c->{localId}, name => $c->{name}, basic => $basic,
      type => $TIDX{ energy_type($c->{name}, $c->{effect}, $basic) }, rarity => $rar,
      artist => $c->{illustrator} || ($pc ? $pc->{artist} // '' : ''), effect => $c->{effect} // '',
      tcgdex => $c->{id}, ptcg => $pc ? $pc->{id} : '' };
    $card->{effect} = '' if $card->{effect} =~ /©|&copy;/;
    push @cards, $card; my $ci = $#cards;

    # Images: TCGdex first (404s properly), then pokemontcg.io, then Scrydex for the energy-only sets
    if ($c->{image})                    { push @images, [$ci, 't', $c->{image} =~ s{^https://assets\.tcgdex\.net/}{}r] }
    elsif ($set->{id} =~ $SCRYDEX)      { push @images, [$ci, 's', "$set->{id}-" . nnum($c->{localId})] }
    elsif ($pc && $pc->{images})        { push @images, [$ci, 'p', $pc->{images}{large} =~ s{^https://images\.pokemontcg\.io/|_hires\.png$}{}gr] }

    my @vd = @{ $c->{variants_detailed} || [] };
    unless (@vd) {
      my $vv = $c->{variants} || { normal => JSON::PP::true };
      push @vd, { type => 'normal' } if $vv->{normal};
      push @vd, { type => 'reverse' } if $vv->{reverse};
      push @vd, { type => 'holo' } if $vv->{holo};
      push @vd, { type => 'normal', stamp => ['1st-edition'] } if $vv->{firstEdition};
      @vd = ({ type => 'normal' }) unless @vd;
    }
    my $base = base_product($set, $card);
    my %seenV;
    for my $v (@vd) {
      my $label = variant_label($v);
      next if $seenV{$label}++;
      push @variants, { card => $ci, label => $label, product => product(variant_product($set, $v, $base)),
        tags => [ tags_for($set, $card, $v) ] };
      my $vi = $#variants;
      my $usd = usd_for($pc, $v); my $eur = eur_for($v);
      if (defined $usd)    { push @market, [$vi, 0 + sprintf('%.2f', $usd), 'USD', 'TCGplayer market'] }
      elsif (defined $eur) { push @market, [$vi, 0 + sprintf('%.2f', $eur), 'EUR', 'Cardmarket trend'] }
    }
  }
}

# pokemontcg.io cards TCGdex doesn't have
for my $k (sort keys %ptcg) {
  next if $ptcgUsed{$k};
  my $pc = $ptcg{$k};
  my ($sid) = split /\|/, $k;
  my $si = set_row('en', $sid);
  my $set = $sets[$si];
  if ($set->{name} eq $sid) { # set unknown to TCGdex: take pokemontcg.io's set details
    @$set{qw(name date symbol logo official)} = ($pc->{set}{name}, ($pc->{set}{releaseDate} // '') =~ s{/}{-}gr,
      $pc->{set}{images}{symbol} // '', $pc->{set}{images}{logo} // '', $pc->{set}{printedTotal} // 0);
  }
  my $basic = (grep { $_ eq 'Basic' } @{ $pc->{subtypes} || [] }) ? 1 : 0;
  my $card = { set => $si, num => $pc->{number}, name => $pc->{name}, basic => $basic,
    type => $TIDX{ energy_type($pc->{name}, '', $basic) }, rarity => $pc->{rarity} || 'None',
    artist => $pc->{artist} // '', effect => '', tcgdex => '', ptcg => $pc->{id} };
  push @cards, $card; my $ci = $#cards;
  push @images, [$ci, 'p', $pc->{images}{large} =~ s{^https://images\.pokemontcg\.io/|_hires\.png$}{}gr] if $pc->{images};
  my @ks = keys %{ $pc->{tcgplayer}{prices} || { normal => {} } };
  for my $pk (sort @ks) {
    my $v = { type => $pk =~ /reverse/i ? 'reverse' : $pk =~ /holo/i ? 'holo' : 'normal',
              ($pk =~ /1stEdition/ ? (stamp => ['1st-edition']) : ()) };
    push @variants, { card => $ci, label => variant_label($v), product => product(base_product($set, $card)),
      tags => [ tags_for($set, $card, $v) ] };
    my $m = $pc->{tcgplayer}{prices}{$pk}{market};
    push @market, [$#variants, 0 + sprintf('%.2f', $m), 'USD', 'TCGplayer market'] if $m;
  }
  warn "pokemontcg.io only: $pc->{id} $pc->{name}\n";
}

# ── Output ────────────────────────────────────────────────────
my @tagNames = do { my %t; $t{$_}++ for map { @{ $_->{tags} } } @variants; sort keys %t };
my %tagIdx = map { $tagNames[$_] => $_ } 0 .. $#tagNames;
my $out = {
  built => do { my @t = gmtime; sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3] },
  types => [ map { { id => $_->[0], name => $_->[1], color => $_->[2] } } @TYPES ],
  eras => \@ERAS,
  sets => [ map { [ @$_{qw(id name lang era date symbol official)} ] } @sets ],
  products => \@products,
  tags => \@tagNames,
  cards => [ map { [ @$_{qw(set num name type basic rarity artist effect)} ] } @cards ],
  images => \@images,
  variants => [ map { [ $_->{card}, $_->{label}, $_->{product}, [ map { $tagIdx{$_} } @{ $_->{tags} } ] ] } @variants ],
  market => \@market,
  schema => {
    sets => [qw(id name lang era_idx release_date symbol_url official_count)],
    cards => [qw(set_idx number name type_idx is_basic rarity artist effect)],
    images => ['card_idx', 'source (t=TCGdex, p=pokemontcg.io, s=Scrydex)', 'path'],
    variants => [qw(card_idx variant_label product_idx tag_idxs)],
    market => [qw(variant_idx amount currency source)],
  },
};
my $js = $json->encode($out);
open my $o, '>:raw', "$root/energy-cards.json" or die $!;
print $o JSON::PP->new->utf8->canonical->pretty->encode($out); close $o;

my $html = slurp("$root/index.html");
$js =~ s{</}{<\\/}g;
$html =~ s{^var _EN=.*;$}{var _EN=$js;}m or die "no `var _EN=` line in index.html\n";
open $o, '>:raw', "$root/index.html" or die $!; print $o $html; close $o;
printf "%d sets, %d cards, %d variants, %d images, %d priced, %d products\n",
  scalar @sets, scalar @cards, scalar @variants, scalar @images, scalar @market, scalar @products;
