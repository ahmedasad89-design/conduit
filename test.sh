#!/usr/bin/env bash
# Run the unit tests.
#
# The Swift Testing runtime ships with the Command Line Tools but is not on any
# default search path, so Package.swift spells out the macro plugin directory
# and two rpaths. Without them `swift test` builds and then dies in dlopen.
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"
exec swift test "$@"
