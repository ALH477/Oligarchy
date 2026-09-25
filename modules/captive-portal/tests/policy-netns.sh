#!/usr/bin/env bash
# Empirical test of modules/captive-portal/vm/policy.nft with network namespaces:
# "guest" behind cp0 (a veth standing in for the tap), "venue" behind uplink0.
#
# Needs root, iproute2, nftables, curl and python3: it runs inside the
# .#test-captive-vm-policy VM (no nested KVM), and ran as-is while the policy
# was written — it is what found the weak-host-model hole the input chain now
# closes. The last check is anti-vacuity: with the table deleted, the drops
# must turn into successes, or the passes above proved nothing.
set -uo pipefail
POLICY=${1:?policy.nft}
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1"; fail=$((fail+1)); }
expect_ok()   { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
expect_fail() { local n=$1; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }

cleanup() {
  nft delete table inet captive_vm 2>/dev/null
  for ns in guest venue; do ip netns pids $ns 2>/dev/null | xargs -r kill 2>/dev/null; ip netns del $ns 2>/dev/null; done
  ip link del cp0 2>/dev/null; ip link del uplink0 2>/dev/null
  kill "${hostpids[@]}" 2>/dev/null
}
trap cleanup EXIT
hostpids=()

ip netns add guest; ip netns add venue
ip link add cp0 type veth peer name g0 netns guest
ip link add uplink0 type veth peer name v0 netns venue
ip addr add 10.207.0.1/30 dev cp0; ip link set cp0 up
ip addr add 192.168.50.1/24 dev uplink0; ip link set uplink0 up
ip -n guest addr add 10.207.0.2/30 dev g0; ip -n guest link set g0 up; ip -n guest link set lo up
ip -n guest route add default via 10.207.0.1
ip -n venue addr add 192.168.50.10/24 dev v0; ip -n venue addr add 100.100.100.100/32 dev v0
ip -n venue link set v0 up; ip -n venue link set lo up
ip -n venue route add 10.207.0.0/30 via 192.168.50.1       # a venue that tries to reach the guest
ip route add 100.100.100.100/32 via 192.168.50.10          # a "tailnet" address that IS routable

echo 1 > /proc/sys/net/ipv4/conf/cp0/forwarding
echo 1 > /proc/sys/net/ipv4/conf/uplink0/forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

sed 's/@UPLINK@/uplink0/g' "$POLICY" | nft -f - || { echo "policy failed to load"; exit 1; }

# Venue services: web on 80, "ssh" on 22, alt web on 8080; each answers with its port.
for p in 80 22 8080 443; do
  ip netns exec venue python3 -c "
import http.server,socketserver,sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200); s.end_headers(); s.wfile.write(('port $p from %s\n' % s.client_address[0]).encode())
    def log_message(s,*a): pass
socketserver.TCPServer.allow_reuse_address=True
socketserver.TCPServer(('0.0.0.0',$p),H).serve_forever()" &
done
# Guest-side web server, for the venue-to-guest check.
ip netns exec guest python3 -m http.server 80 --bind 10.207.0.2 >/dev/null 2>&1 &
# Host services: DNS responder on 10.207.0.1:53 (udp), and an "ssh" on 2222.
python3 -c "
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('10.207.0.1',53))
while True:
    d,a=s.recvfrom(512); s.sendto(d[:2]+b'OK',a)" & hostpids+=($!)
python3 -m http.server 2222 --bind 0.0.0.0 >/dev/null 2>&1 & hostpids+=($!)
sleep 1.5

G() { ip netns exec guest "$@"; }
V() { ip netns exec venue "$@"; }
curl_g() { G curl -s --max-time 3 "$@"; }

out=$(curl_g http://192.168.50.10/)
if [[ "$out" == "port 80 from 192.168.50.1" ]]; then
  ok "guest -> venue:80 allowed, venue sees the HOST address (NAT)"
else
  bad "guest -> venue:80 ($out)"
fi
expect_fail "guest -> venue:22 dropped"            curl_g http://192.168.50.10:22/
expect_fail "guest -> venue:8080 dropped"          curl_g http://192.168.50.10:8080/
expect_fail "guest -> 100.100.100.100:80 (tailnet range, routable) dropped" curl_g http://100.100.100.100/
expect_fail "guest -> host 10.207.0.1:2222 dropped" curl_g http://10.207.0.1:2222/
expect_fail "guest -> host uplink address 192.168.50.1:2222 dropped" curl_g http://192.168.50.1:2222/
dns() { G python3 -c "
import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(2)
s.sendto(b'\x12\x34query',(sys.argv[1],53)); d,_=s.recvfrom(512); sys.exit(0 if d==b'\x12\x34OK' else 1)" "$1"; }
expect_ok   "guest -> forwarder 10.207.0.1:53/udp answered" dns 10.207.0.1
expect_fail "guest -> venue:53/udp (outside DNS) dropped"   dns 192.168.50.10
quic() {
  rm -f /tmp/quic.got
  V timeout 3 python3 -c "
import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('0.0.0.0',443)); s.settimeout(2.5)
d,a=s.recvfrom(64); open('/tmp/quic.got','w').write(a[0])" &
  local lp=$!; sleep 0.4
  G python3 -c "
import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.sendto(b'x',('192.168.50.10',443))"
  wait $lp; test -s /tmp/quic.got
}
expect_fail "guest -> venue:443/udp (QUIC) dropped" quic
expect_fail "venue -> guest:80 new connection dropped" V curl -s --max-time 3 http://10.207.0.2/
expect_fail "venue -> host 10.207.0.1:2222 through the uplink (weak host model) dropped" V curl -s --max-time 3 http://10.207.0.1:2222/
lan_dns() { V python3 -c "
import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(2)
s.sendto(b'\x12\x34query',('10.207.0.1',53)); d,_=s.recvfrom(512); sys.exit(0 if d==b'\x12\x34OK' else 1)"; }
expect_fail "venue -> forwarder 10.207.0.1:53 through the uplink dropped" lan_dns
nft delete table inet captive_vm
expect_ok "without the table, guest -> venue:22 is reachable (the forward drops were the policy's)" curl_g http://192.168.50.10:22/
expect_ok "without the table, venue -> host 10.207.0.1:2222 is reachable (the input drops were the policy's)" V curl -s --max-time 3 http://10.207.0.1:2222/

echo; echo "policy-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
