#!/bin/sh
set -eu

exec wget --spider --quiet http://127.0.0.1:4000/healthz
