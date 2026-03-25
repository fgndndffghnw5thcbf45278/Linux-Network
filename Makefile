# =============================================================================
# Makefile — Linux Network Namespace Simulation
# Usage: sudo make <target>
# =============================================================================

SCRIPT := ./netns_setup.sh

.PHONY: all setup teardown test status help

# Default target
all: setup test

## setup    : Create bridges, namespaces, veth pairs, IPs, and routes
setup:
	@bash $(SCRIPT) setup

## teardown : Remove all network namespaces, bridges, and virtual interfaces
teardown:
	@bash $(SCRIPT) teardown

## test     : Run ping connectivity tests between ns1 and ns2
test:
	@bash $(SCRIPT) test

## status   : Display IP addresses inside each namespace
status:
	@bash $(SCRIPT) status

## help     : Show this help message
help:
	@echo "Linux Network Namespace Simulation"
	@echo ""
	@echo "Available targets (run with: sudo make <target>):"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'
