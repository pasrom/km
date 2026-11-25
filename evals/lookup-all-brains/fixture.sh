#!/usr/bin/env bash
# A brain with two mounted brains; the fact the prompt asks for is only in the second mount's merged doc.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/brain.sh"
brain_with_two_peers "$PWD"
