#!/bin/sh
# Downloads the raw energy-card data the Energy Cards tab is built from.
#   sh scripts/fetch-energy.sh <raw-dir>
# Then: perl scripts/build-energy.pl <raw-dir>
# Sources: TCGdex REST (EN + JA cards and sets, incl. per-variant detail and
# Cardmarket pricing) and pokemontcg.io (TCGplayer USD market prices, extra images).
set -e
D=${1:?usage: fetch-energy.sh <raw-dir>}
mkdir -p "$D/en" "$D/ja" "$D/sets_en" "$D/sets_ja"
for L in en ja; do
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
# Scrydex art for JA cards TCGdex has no image for (<set>_ja-<n>); a bad id
# returns HTTP 200 with a card-back, so reject by the card-back's md5.
BACK=8d6b1f7c375b5d51d9b3980bd413175a
perl -MJSON::PP -e 'local $/; for (@ARGV) { open my $f, "<", $_; my $c = eval { decode_json(<$f>) } or next;
  next if $c->{image}; (my $s = lc $c->{set}{id}) =~ s/-//g; (my $n = $c->{localId}) =~ s/^0+(?=\d)//;
  print "$c->{id} ${s}_ja-$n\n" }' "$D"/ja/*.json > "$D/scrydex-try.txt"
: > "$D/scrydex.txt"
while read id sx; do
  h=$(curl -s -m 30 "https://images.scrydex.com/pokemon/$sx/small" | md5sum | cut -d' ' -f1)
  [ "$h" != "$BACK" ] && [ "$h" != d41d8cd98f00b204e9800998ecf8427e ] && echo "$id $sx" >> "$D/scrydex.txt"
done < "$D/scrydex-try.txt"
echo "fetched: $(ls "$D/en" | wc -l) EN, $(ls "$D/ja" | wc -l) JA, $((p-1)) pokemontcg.io pages"
