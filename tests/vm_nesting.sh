#!/bin/bash
set -eux

waitSnapdSeed() (
  set +x
  for i in $(seq 60); do # Wait up to 60s.
    if systemctl show snapd.seeded.service --value --property SubState | grep -qx exited; then
      return 0 # Success.
    fi

    sleep 1
  done

  echo "snapd not seeded after ${i}s"
  return 1 # Failed.
)

cleanup() {
    echo ""
    if [ "${FAIL}" = "1" ]; then
        echo "Test failed"
        exit 1
    fi

    echo "Test passed"
    exit 0
}

FAIL=1
trap cleanup EXIT HUP INT TERM

# Wait for snapd seeding.
waitSnapdSeed

# Install LXD.
snap remove lxd || true
snap install lxd --channel=latest/edge
lxd waitready --timeout=300

# Configure LXD.
lxc project switch default
lxc storage create default zfs size=30GiB
lxc network create lxdbr0

instanceImage="ubuntu:22.04"
snapChannel="latest/edge"

function parallel() {
	seq "$1" | xargs -P "$1" -I "{}" "${@:2}"
}

function init() {
	vm="${2:-}"
	if [ -z "${vm}" ]
	then
		parallel "$1" lxc init "${instanceImage}" "t{}" -s default -n lxdbr0
	else
	    parallel "$1" lxc init "${instanceImage}" "t{}" "${vm}" -s default -n lxdbr0
	fi
}

function conf() {
	parallel "$1" lxc config set "t{}" "$2"
}

function device_add() {
	parallel "$1" lxc config device add "t{}" "$2" "$3" "$4"
}

function start() {
	instances=()
	for i in $(seq "$1"); do
		instances["$i"]="t$i"
	done

	echo "Start ${instances[*]}"
	lxc start -f "${instances[@]}"
}

function wait() {
	parallel "$1" bash -c "while true; do if lxc shell t{}; then break; fi; sleep 1; done"
}

function copy() {
	parallel "$1" lxc file push "$2" "t{}$3"
}

function cmd() {
	parallel "$1" lxc exec "t{}" -- bash -c "$2"
}

function delete() {
	instances=()
	for i in $(seq "$1"); do
		instances["$i"]="t$i"
	done

	echo "Delete ${instances[*]}"
	lxc delete -f "${instances[@]}"
}

# Test 10 VMs in parallel.
init 10 --vm
start 10
delete 10

# Test vsock ID collision.
init 10 --vm
conf 10 volatile.vsock_id=42
start 10
delete 10

# Test 5 VMs each with one nested VM.
init 5 --vm
start 5
wait 5
cmd 5 "snap wait system seed.loaded && snap refresh lxd --channel $snapChannel"
cmd 5 "lxd init --auto"
cmd 5 "systemctl reload snap.lxd.daemon"
cmd 5 "lxc launch ${instanceImage} nested --vm -c limits.memory=512MiB -d root,size=5GiB"
delete 5

# Test 5 containers each with one nested VM.
init 5
conf 5 security.nesting=true
device_add 5 kvm unix-char source=/dev/kvm
device_add 5 vhost-net unix-char source=/dev/vhost-net
device_add 5 vhost-vsock unix-char source=/dev/vhost-vsock
device_add 5 vsock unix-char source=/dev/vsock
start 5
cmd 5 "snap wait system seed.loaded && snap refresh lxd --channel $snapChannel"
cmd 5 "lxd init --auto"
cmd 5 "systemctl reload snap.lxd.daemon"
cmd 5 "lxc launch ${instanceImage} nested --vm -c limits.memory=512MiB -d root,size=5GiB"
delete 5

lxc network delete lxdbr0
lxc storage delete default

FAIL=0
