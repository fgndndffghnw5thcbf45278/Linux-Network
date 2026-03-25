#!/bin/bash
# =============================================================================
# Linux Network Namespace Simulation
# Two isolated networks connected via a router namespace
#
# Topology:
#   ns1 (10.0.1.2/24) ──── br0 (10.0.1.1/24) ──── router-ns ──── br1 (10.0.2.1/24) ──── ns2 (10.0.2.2/24)
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "This script must be run as root (sudo $0)"

# =============================================================================
# SETUP
# =============================================================================
setup() {
  echo -e "\n${CYAN}════════════════════════════════════════${NC}"
  echo -e "${CYAN}  Network Namespace Simulation — Setup  ${NC}"
  echo -e "${CYAN}════════════════════════════════════════${NC}\n"

  # ── 1. Network Bridges ──────────────────────────────────────────────────────
  info "Creating bridges br0 and br1..."

  ip link add br0 type bridge
  ip link add br1 type bridge

  ip addr add 10.0.1.1/24 dev br0
  ip addr add 10.0.2.1/24 dev br1

  ip link set br0 up
  ip link set br1 up

  success "Bridges br0 (10.0.1.1/24) and br1 (10.0.2.1/24) are up"

  # ── 2. Network Namespaces ───────────────────────────────────────────────────
  info "Creating namespaces: ns1, ns2, router-ns..."

  ip netns add ns1
  ip netns add ns2
  ip netns add router-ns

  success "Namespaces created: $(ip netns list | tr '\n' ' ')"

  # ── 3. Virtual Ethernet Pairs ───────────────────────────────────────────────
  info "Creating veth pairs..."

  # ns1 ↔ br0
  ip link add veth-ns1    type veth peer name veth-ns1-br
  # ns2 ↔ br1
  ip link add veth-ns2    type veth peer name veth-ns2-br
  # router ↔ br0
  ip link add veth-rtr0   type veth peer name veth-rtr0-br
  # router ↔ br1
  ip link add veth-rtr1   type veth peer name veth-rtr1-br

  success "veth pairs created"

  # ── 4. Attach peers to namespaces ──────────────────────────────────────────
  info "Moving veth peers into namespaces..."

  ip link set veth-ns1  netns ns1
  ip link set veth-ns2  netns ns2
  ip link set veth-rtr0 netns router-ns
  ip link set veth-rtr1 netns router-ns

  # Attach bridge-side peers to bridges
  ip link set veth-ns1-br  master br0
  ip link set veth-ns2-br  master br1
  ip link set veth-rtr0-br master br0
  ip link set veth-rtr1-br master br1

  # Bring up bridge-side peers
  ip link set veth-ns1-br  up
  ip link set veth-ns2-br  up
  ip link set veth-rtr0-br up
  ip link set veth-rtr1-br up

  success "veth peers attached to bridges and namespaces"

  # ── 5. IP Addressing ────────────────────────────────────────────────────────
  info "Assigning IP addresses..."

  # ns1
  ip netns exec ns1 ip link set lo up
  ip netns exec ns1 ip link set veth-ns1 up
  ip netns exec ns1 ip addr add 10.0.1.2/24 dev veth-ns1

  # ns2
  ip netns exec ns2 ip link set lo up
  ip netns exec ns2 ip link set veth-ns2 up
  ip netns exec ns2 ip addr add 10.0.2.2/24 dev veth-ns2

  # router-ns
  ip netns exec router-ns ip link set lo up
  ip netns exec router-ns ip link set veth-rtr0 up
  ip netns exec router-ns ip link set veth-rtr1 up
  ip netns exec router-ns ip addr add 10.0.1.254/24 dev veth-rtr0
  ip netns exec router-ns ip addr add 10.0.2.254/24 dev veth-rtr1

  success "IP addresses assigned"

  # ── 6. Routing ──────────────────────────────────────────────────────────────
  info "Configuring routes and enabling IP forwarding..."

  # Default routes for ns1 and ns2 via router
  ip netns exec ns1      ip route add default via 10.0.1.254
  ip netns exec ns2      ip route add default via 10.0.2.254

  # Enable IP forwarding in router-ns
  ip netns exec router-ns sysctl -qw net.ipv4.ip_forward=1

  # Host routing (optional — lets the host reach both subnets)
  ip route add 10.0.1.0/24 dev br0 2>/dev/null || true
  ip route add 10.0.2.0/24 dev br1 2>/dev/null || true

  success "Routing configured, IP forwarding enabled in router-ns"

  echo -e "\n${GREEN}✔ Setup complete!${NC}"
  show_topology
}

# =============================================================================
# TEST CONNECTIVITY
# =============================================================================
test_connectivity() {
  echo -e "\n${CYAN}══════════════════════════════════${NC}"
  echo -e "${CYAN}  Connectivity Tests               ${NC}"
  echo -e "${CYAN}══════════════════════════════════${NC}\n"

  run_ping() {
    local src_ns="$1" src_label="$2" dst_ip="$3" dst_label="$4"
    echo -ne "  Ping ${src_label} → ${dst_label} (${dst_ip})... "
    if ip netns exec "$src_ns" ping -c 2 -W 2 "$dst_ip" &>/dev/null; then
      echo -e "${GREEN}✔ OK${NC}"
    else
      echo -e "${RED}✘ FAILED${NC}"
    fi
  }

  echo "Loopback:"
  run_ping ns1       "ns1 lo"     127.0.0.1    "lo"
  run_ping ns2       "ns2 lo"     127.0.0.1    "lo"

  echo ""
  echo "Within network 1 (10.0.1.0/24):"
  run_ping ns1       "ns1"        10.0.1.1     "br0 (host)"
  run_ping ns1       "ns1"        10.0.1.254   "router veth-rtr0"

  echo ""
  echo "Within network 2 (10.0.2.0/24):"
  run_ping ns2       "ns2"        10.0.2.1     "br1 (host)"
  run_ping ns2       "ns2"        10.0.2.254   "router veth-rtr1"

  echo ""
  echo "Cross-network (through router):"
  run_ping ns1       "ns1"        10.0.2.2     "ns2"
  run_ping ns2       "ns2"        10.0.1.2     "ns1"
  run_ping ns1       "ns1"        10.0.2.254   "router br1-side"
  run_ping ns2       "ns2"        10.0.1.254   "router br0-side"

  echo ""
}

# =============================================================================
# SHOW TOPOLOGY
# =============================================================================
show_topology() {
  echo -e "\n${CYAN}Network Topology${NC}"
  echo "────────────────────────────────────────────────────────────────────"
  echo ""
  echo "  [ns1]                                               [ns2]"
  echo "  10.0.1.2/24                                     10.0.2.2/24"
  echo "  veth-ns1                                         veth-ns2"
  echo "     │                                                 │"
  echo "  veth-ns1-br                                   veth-ns2-br"
  echo "     │                                                 │"
  echo "  [br0]─────────────[router-ns]─────────────────[br1]"
  echo "  10.0.1.1/24   veth-rtr0 │ veth-rtr1        10.0.2.1/24"
  echo "               10.0.1.254 │ 10.0.2.254"
  echo ""
  echo "  Subnet A: 10.0.1.0/24  (ns1, router-ns eth0, br0)"
  echo "  Subnet B: 10.0.2.0/24  (ns2, router-ns eth1, br1)"
  echo ""
}

# =============================================================================
# SHOW STATUS
# =============================================================================
show_status() {
  echo -e "\n${CYAN}Current State${NC}"
  echo "────────────────────────────────────────────────────────────────────"
  echo ""
  for ns in ns1 ns2 router-ns; do
    echo -e "  ${YELLOW}[$ns]${NC}"
    ip netns exec "$ns" ip addr show 2>/dev/null | grep -E "inet |state" | sed 's/^/    /'
    echo ""
  done
}

# =============================================================================
# TEARDOWN
# =============================================================================
teardown() {
  echo -e "\n${CYAN}═══════════════════════════════════════════${NC}"
  echo -e "${CYAN}  Network Namespace Simulation — Teardown  ${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════${NC}\n"

  warn "Removing namespaces, bridges, and veth pairs..."

  # Delete namespaces (removes all veth peers inside them automatically)
  for ns in ns1 ns2 router-ns; do
    if ip netns list | grep -q "^$ns"; then
      ip netns del "$ns" && info "Deleted namespace: $ns"
    fi
  done

  # Remove bridge-side veths that still exist in the host
  for iface in veth-ns1-br veth-ns2-br veth-rtr0-br veth-rtr1-br; do
    if ip link show "$iface" &>/dev/null; then
      ip link del "$iface" && info "Deleted interface: $iface"
    fi
  done

  # Delete bridges
  for br in br0 br1; do
    if ip link show "$br" &>/dev/null; then
      ip link set "$br" down
      ip link del "$br" && info "Deleted bridge: $br"
    fi
  done

  # Remove host routes
  ip route del 10.0.1.0/24 2>/dev/null || true
  ip route del 10.0.2.0/24 2>/dev/null || true

  success "Teardown complete — environment is clean"
}

# =============================================================================
# ENTRYPOINT
# =============================================================================
usage() {
  echo "Usage: $0 {setup|teardown|test|status|all}"
  echo ""
  echo "  setup    — create bridges, namespaces, veth pairs, IPs, routes"
  echo "  teardown — remove all created network objects"
  echo "  test     — run ping tests between namespaces"
  echo "  status   — display current IP configuration per namespace"
  echo "  all      — setup + test"
}

case "${1:-}" in
  setup)    setup ;;
  teardown) teardown ;;
  test)     test_connectivity ;;
  status)   show_status ;;
  all)      setup; test_connectivity ;;
  *)        usage; exit 1 ;;
esac
