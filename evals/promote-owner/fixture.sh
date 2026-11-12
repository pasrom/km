#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/../lib/brain.sh"
team_brain "$PWD" EV "EV, MTA"
inbox_note "$PWD" EV
