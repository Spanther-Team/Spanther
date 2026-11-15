#!/bin/bash
# Turns the error lines of a failed build or test run into one annotation on the check run, so why a job failed
# can be read on the pull request's checks (and through the public API) without opening the whole log.
# usage: annotate-errors.sh <log file> <title>
log=$1
title=$2
lines=$(grep -E 'error: |Fatal error|failed \(' "$log" | sed -E 's#^.*/(SpantherGaze/)#\1#' | awk '!seen[$0]++' | head -n 80)
[ -n "$lines" ] || lines=$(tail -n 60 "$log")
lines=${lines//'%'/'%25'}
lines=${lines//$'\r'/}
lines=${lines//$'\n'/'%0A'}
echo "::error title=$title::$lines"
