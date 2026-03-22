#!/bin/bash
echo "--- OS History ---"
if command -v dnf &>/dev/null; then
    dnf history list | head -n 4 | tail -n 1
elif command -v apt-get &>/dev/null; then
    grep "End-Date" /var/log/apt/history.log | tail -n 1
elif command -v zypper &>/dev/null; then
    tail -n 20 /var/log/zypp/history | grep "patch" | tail -n 1
fi

echo "--- Kernel Audit ---"
RUNNING=$(uname -r)
if [[ -f /usr/bin/rpm ]]; then
    INSTALLED=$(rpm -q kernel --last | head -n 1 | awk '{print $1}' | sed 's/kernel-//')
    echo "Running: $RUNNING"
    echo "Installed: $INSTALLED"
    if [[ "$RUNNING" != *"$INSTALLED"* ]]; then
        echo "RESULT: REBOOT_REQUIRED"
    else
        echo "RESULT: OK"
    fi
else
    echo "Running: $RUNNING"
fi
