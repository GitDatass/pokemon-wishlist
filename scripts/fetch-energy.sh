#!/bin/sh
# Downloads the raw energy-card data the Energy Cards tab is built from.
#   sh scripts/fetch-energy.sh <raw-dir>
# Then: perl scripts/build-energy.pl <raw-dir>
# English only. Sources: TCGdex REST (cards and sets, incl. per-variant detail and
# Cardmarket pricing) and pokemontcg.io (TCGplayer USD market prices, extra images).
set -e
D=${1:?usage: fetch-energy.sh <raw-dir>}
mkdir -p "$D/en" "$D/sets_en"
for L in en; do
  curl -s "https://api.tcgdex.net/v2/$L/cards?category=Energy" -o "$D/${L}_brief.json"
  grep -o '"id":"[^"]*","localId"' "$D/${L}_brief.json" | cut -d'"' -f4 \
    | xargs -P 8 -I{} sh -c "curl -s -m 60 'https://api.tcgdex.net/v2/$L/cards/{}' -o '$D/$L/{}.json'"
  perl -MJSON::PP -e 'local $/; my %s; for (@ARGV) { open my $f, "<", $_; my $c = eval { decode_json(<$f>) } or next; $s{$c->{set}{id}} = 1 } print "$_\n" for sort keys %s' "$D/$L"/*.json \
    | xargs -P 8 -I{} sh -c "curl -s -m 60 'https://api.tcgdex.net/v2/$L/sets/{}' -o '$D/sets_$L/{}.json'"
done
# pokemontcg.io is flaky with big pages: 50 per page, retried
p=1
while :; do
  for try in 1 2 3 4 5; do
    curl -s -m 120 "https://api.pokemontcg.io/v2/cards?q=supertype:Energy&pageSize=50&page=$p&orderBy=id&select=id,name,number,rarity,subtypes,set,images,tcgplayer,artist" -o "$D/pa$p.json"
    grep -q '"data"' "$D/pa$p.json" && break
  done
  grep -q '"data":\[\]' "$D/pa$p.json" && { rm "$D/pa$p.json"; break; }
  p=$((p+1))
done
echo "fetched: $(ls "$D/en" | wc -l) EN, $((p-1)) pokemontcg.io pages"
