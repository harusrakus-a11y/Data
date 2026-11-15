#!/bin/sh
# arca-install.sh v4 - pasang tunnel Arca ke satu VPS (jalankan kat ROUTER)
# Guna:  sh /root/arca-install.sh IP USER PASSWORD [PORT[,PORT2,...]] [PORT_BUNGKUS]
# v4: kalau PORT_BUNGKUS diberi, SSH dibungkus dalam Xray Shadowsocks (kata laluan sama dengan password akaun)
#     supaya tak dikesan dan disekat sebagai SSH oleh rangkaian. Pusat mesti jalankan pusat-sshwrap.sh dahulu.
# v3: boleh bagi beberapa port (contoh 2222,22). Kalau satu port tersangkut, tukar ke port seterusnya sendiri.
#     Sambungan yang tersangkut (data tak sampai) dikesan dan dimulakan semula tanpa tunggu selama-lamanya.
# Baris lengkap (IP dan password sebenar) dipaparkan oleh geo-vps.sh kat VPS.
R=${R:-/root}; RC=${RC:-/etc/rc.local}
IP=$1; U=$2; PW=$3; DB=$(echo "${4:-109}" | tr ',' ' '); WP=$5

[ -n "$IP" ] && [ -n "$U" ] && [ -n "$PW" ] || { echo "Guna: sh $R/arca-install.sh IP USER PASSWORD [PORT]"; exit 1; }
echo "$IP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || { echo "RALAT: IP '$IP' tak sah. Guna IP VPS sebenar."; exit 1; }
case "$PW" in PASSWORD|PASSWORD_*|*DARI_VPS*) echo "RALAT: password tu contoh. Guna password sebenar dari geo-vps.sh."; exit 1;; esac
for p in $DB; do echo "$p" | grep -Eq '^[0-9]+$' || { echo "RALAT: port '$p' tak sah."; exit 1; }; done
if [ -n "$WP" ]; then
  echo "$WP" | grep -Eq '^[0-9]+$' || { echo "RALAT: port bungkus '$WP' tak sah."; exit 1; }
  echo "$PW" | grep -Eq '^[A-Za-z0-9]+$' || { echo "RALAT: mod bungkus perlukan password huruf dan nombor sahaja."; exit 1; }
  [ "$(echo $DB | wc -w)" = 1 ] || { echo "RALAT: mod bungkus guna SATU port SSH sahaja (port SSH kat pusat)."; exit 1; }
fi

command -v xray >/dev/null 2>&1 || echo "AMARAN: xray tak ada kat router (tunnel perlukan dia)."
command -v dbclient >/dev/null 2>&1 || echo "AMARAN: dbclient tak ada kat router."

# 1. skrip tunnel untuk VPS ini
if [ -n "$WP" ]; then
cat > $R/tpl.$$ <<'EOS'
#!/bin/sh
IP=__IP__; U=__U__; P='__P__'; WP=__WP__; DB=__DB__; LP=2201; TP=1081
LOG=/tmp/tun-$IP.log; WC=/root/wrap-$IP.json
kxw() { kill $(ps w | grep "[w]rap-$IP.json" | awk '{print $1}') 2>/dev/null; }
mati() { kill $(ps w | grep "[d]bclient.* -p $LP " | awk '{print $1}') 2>/dev/null; kxw; }
tersangkut() { netstat -tn 2>/dev/null | awk -v a="$IP:$WP" -v b="127.0.0.1:$LP" '($5==a || $5==b) && ($3>0 || $6=="SYN_SENT"){f=1} END{exit !f}'; }
hidup() { ps w | grep "[d]bclient" | grep -q " -p $LP "; }
while true; do
  ps w | grep -q "[m]ysocks.json" || { echo '{"inbounds":[{"listen":"127.0.0.1","port":1080,"protocol":"socks"}],"outbounds":[{"protocol":"freedom"}]}' > /root/mysocks.json; (xray run -c /root/mysocks.json >/dev/null 2>&1 &); }
  ps w | grep -q "[w]rap-$IP.json" || { echo '{"log":{"loglevel":"warning"},"inbounds":[{"listen":"127.0.0.1","port":2201,"protocol":"dokodemo-door","settings":{"address":"127.0.0.1","port":__DB__,"network":"tcp"}}],"outbounds":[{"protocol":"shadowsocks","settings":{"servers":[{"address":"__IP__","port":__WP__,"method":"chacha20-ietf-poly1305","password":"__P__"}]}}]}' > $WC; (xray run -c $WC >/dev/null 2>&1 &); sleep 1; }
  sleep 2
  sshpass -p "$P" dbclient -y -N -K 20 -p $LP -R $TP:127.0.0.1:1080 $U@127.0.0.1 >$LOG 2>&1 &
  sleep 15
  if grep -qi "forward request failed" $LOG; then mati; sleep 10; continue; fi
  if ! hidup; then kxw; sleep 3; continue; fi
  if tersangkut; then mati; sleep 3; continue; fi
  S=0
  while hidup; do
    sleep 10
    if tersangkut; then S=$((S+1)); else S=0; fi
    [ $S -ge 2 ] && { mati; break; }
  done
  sleep 5
done
EOS
else
cat > $R/tpl.$$ <<'EOS'
#!/bin/sh
IP=__IP__; U=__U__; P='__P__'; PORTS="__DB__"; TP=1081
LOG=/tmp/tun-$IP.log; K=0
set -- $PORTS; N=$#
mati() { kill $(ps w | grep "[d]bclient.*@$IP" | awk '{print $1}') 2>/dev/null; }
tersangkut() { netstat -tn 2>/dev/null | awk -v t="$IP:$DB" '$5==t && ($3>0 || $6=="SYN_SENT"){f=1} END{exit !f}'; }
hidup() { ps w | grep "[d]bclient" | grep -q "@$IP"; }
while true; do
  ps w | grep -q "[m]ysocks.json" || { echo '{"inbounds":[{"listen":"127.0.0.1","port":1080,"protocol":"socks"}],"outbounds":[{"protocol":"freedom"}]}' > /root/mysocks.json; (xray run -c /root/mysocks.json >/dev/null 2>&1 &); }
  sleep 2
  DB=$(echo $PORTS | cut -d' ' -f$((K % N + 1)))
  sshpass -p "$P" dbclient -y -N -K 20 -p $DB -R $TP:127.0.0.1:1080 $U@$IP >$LOG 2>&1 &
  sleep 15
  if grep -qi "forward request failed" $LOG; then mati; sleep 10; continue; fi
  if ! hidup; then K=$((K+1)); sleep 3; continue; fi
  if tersangkut; then mati; K=$((K+1)); sleep 3; continue; fi
  S=0
  while hidup; do
    sleep 10
    if tersangkut; then S=$((S+1)); else S=0; fi
    [ $S -ge 2 ] && { mati; K=$((K+1)); break; }
  done
  sleep 5
done
EOS
fi
PE=$(printf '%s' "$PW" | sed 's/[&/\\]/\\&/g')
sed -e "s/__IP__/$IP/" -e "s/__U__/$U/" -e "s/__P__/$PE/" -e "s/__DB__/$DB/" -e "s/__WP__/$WP/" $R/tpl.$$ > $R/tunnel-$IP.sh
rm -f $R/tpl.$$
chmod +x $R/tunnel-$IP.sh

# 2. mula sendiri bila router hidup (sekali sahaja)
sed -i '/sleep 30; \/root\/tunnel/d' $RC
grep -q 'for t in /root/tunnel' $RC || sed -i '1a (sleep 20; for t in /root/tunnel-*.sh; do /bin/sh $t >/dev/null 2>&1 & done) >/dev/null 2>&1 &' $RC

# 3. matikan Localhost Proxy Passwall kalau ada
[ "$(uci -q get passwall.@global[0].localhost_proxy)" = 1 ] && { uci set passwall.@global[0].localhost_proxy=0; uci commit passwall; [ -x /etc/init.d/passwall ] && /etc/init.d/passwall restart; }

# 4. buang kunci host lama, hentikan tunnel lama untuk IP ini, mula
sed -i "/$IP/d" $R/.ssh/known_hosts 2>/dev/null
kill $(ps w | grep -E "[t]unnel-$IP.sh|[d]bclient.*@$IP|[w]rap-$IP.json|[d]bclient.* -p 2201 " | awk '{print $1}') 2>/dev/null
(nohup sh $R/tunnel-$IP.sh >/dev/null 2>&1 &)

# 5. pasang sshpass sendiri bila internet ada
if ! command -v sshpass >/dev/null 2>&1; then
  (nohup sh -c 'while ! command -v sshpass >/dev/null 2>&1; do ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 && { opkg update >/dev/null 2>&1; opkg install sshpass >/dev/null 2>&1; }; sleep 20; done' >/dev/null 2>&1 &)
  echo "sshpass belum ada. Dipasang sendiri di latar bila internet ada."
fi

# 6. bina fail pulih /root/arca-restore.sh (ada password, simpan elok-elok)
O=$R/arca-restore.sh
{
echo '#!/bin/sh'
echo 'opkg update >/dev/null 2>&1; opkg install sshpass >/dev/null 2>&1'
for f in $R/tunnel-*.sh; do
  echo "cat > $f <<'EOS'"
  cat $f
  echo "EOS"
  echo "chmod +x $f"
done
cat <<'EOT'
sed -i '/sleep 30; \/root\/tunnel/d' /etc/rc.local
grep -q 'for t in /root/tunnel' /etc/rc.local || sed -i '1a (sleep 20; for t in /root/tunnel-*.sh; do /bin/sh $t >/dev/null 2>&1 & done) >/dev/null 2>&1 &' /etc/rc.local
for t in /root/tunnel-*.sh; do (nohup /bin/sh $t >/dev/null 2>&1 &); done
sleep 20; ps w | grep "[d]bclient" | grep -v sshpass | grep -o "@[0-9.]*"
EOT
} > $O
chmod 600 $O

echo "Tunnel ke $IP dimulakan (port: $DB${WP:+, bungkus: $WP}). Menunggu 30 saat..."
sleep 30
PAT="@$IP"; [ -n "$WP" ] && PAT=" -p 2201 "
if ps w | grep "[d]bclient" | grep -q -- "$PAT"; then
  BAD=$(netstat -tn 2>/dev/null | awk -v ip="$IP" '{n=split($5,a,":"); if ((a[1]==ip || $5 ~ /^127\.0\.0\.1:2201$/) && ($3>0 || $6=="SYN_SENT")) f=1} END{print f+0}')
  if [ "$BAD" = 1 ]; then echo "TUNNEL_TERSANGKUT (data tak sampai ke pusat). Dia akan cuba lagi sendiri. Tunggu 30 saat dan semak status kat pusat."
  else echo "TUNNEL_HIDUP"; fi
else
  echo "TUNNEL_GAGAL. Semak: cat /tmp/tun-$IP.log"
  if [ -n "$WP" ]; then xray run -test -c $R/wrap-$IP.json 2>&1 | tail -3; fi
fi
echo "Fail pulih: $O (download guna SFTP dan simpan, ada password)."
