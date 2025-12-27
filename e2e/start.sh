#!/bin/bash
set -e

# Start EPMD in daemon mode for distributed Erlang
epmd -daemon

# Give EPMD time to start
sleep 1

# Run the Elixir application
exec mix run --no-halt
