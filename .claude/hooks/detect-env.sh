#!/bin/bash
# Detect whether we're running on the OpenClaw host or the dev machine.
# Source this from hooks: source "$(dirname "$0")/detect-env.sh"
#
# Sets: IS_HOST=true/false
#
# Host detection: openclaw CLI exists + live openclaw.json config
# Dev detection: no live gateway config

if command -v openclaw &>/dev/null && [[ -f ~/.openclaw/openclaw.json ]]; then
    IS_HOST=true
else
    IS_HOST=false
fi
