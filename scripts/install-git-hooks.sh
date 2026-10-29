#!/bin/sh
set -eu

git config core.hooksPath .githooks
printf '%s\n' 'Installed repository Git hooks. Config dropdown will sync on config commits.'
