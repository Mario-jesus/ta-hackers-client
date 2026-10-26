# Trickster Arts Hackers reverse engineering
![GitHub](https://img.shields.io/github/license/animotto/ta-hackers)
[![Tests](https://github.com/animotto/ta-hackers/actions/workflows/tests.yml/badge.svg)](https://github.com/animotto/ta-hackers/actions/workflows/tests.yml)

## Overview
This tool provides a sandbox for researching of the network API of the Hackers mobile game, originally developed by Trickster Arts

## Disclaimer
This project is for research purposes only. All source code is provided as is. I don't condone of exploiting vulnerabilities or cheating in this game, you act at your own risk.

## Sandbox
It uses my [sandbox-ruby](https://github.com/animotto/sandbox-ruby) gem

The sandbox consists of the following contexts:
- `chat` Internal chat
- `market` Purchases of various ingame items
- `mission` Managing your missions
- `net` Maintenance your network
- `prog` Managing your programs
- `query` Creating and analyzing queries to the API server
- `script` Running your own scripts to interact with the sandbox
- `top` Top players
- `world` World map

## How to run it

Clone the repository to your local machine and prepare the environment:
```console
git clone https://github.com/animotto/ta-hackers
cd ta-hackers
bundle install
export RUBYLIB=$PWD/lib
```

Create a new account and write the credentials to the config named *my*:
```console
./bin/sandbox -n my
```

Run the sandbox with the config *my*:
```console
./bin/sandbox -c my
```

## Anti-AFK session cycle

Run `script run antiafk` in an authenticated sandbox. Only one anti-AFK job
may run at a time (including `./antiafk` aliases). Use `script jobs` to find
its job ID and `script kill <id>` to stop it.

| Phase | Local behavior |
|-------|----------------|
| Online | Minimal authentication followed by player loading about every 60 seconds; a monotonic clock measures each three-hour online cycle. |
| Drain and silence | Reject new requests throughout this tool, wait for admitted requests to finish, clear the local session ID, then remain silent for a randomly chosen inclusive 240–300 seconds. |
| Recovery | Only the anti-AFK owner can send recovery requests. Authentication **and** player loading must succeed before other traffic reopens. Request errors retry indefinitely after 10, 20, 40, 80, 160, then 180 seconds (capped); successful recovery resets the cycle and backoff. |

Other scripts and interactive requests fail immediately with an actionable
`Hackers::RequestError` during drain, silence, and recovery; they are not queued
for replay with stale sessions or mutations. A maintenance failure also enters
exclusive recovery without postponing the original three-hour silence deadline.
Authentication already in progress is drained through response parsing and local
state updates before silence starts, so it cannot overwrite a recovered session.
Logs describe phases without session IDs or credentials.

**Stopping the job cancels its control:** cleanup releases the traffic gate,
even during drain, silence, or recovery. This deliberately ends the scheduled
silence early; a cleared session remains cleared unless recovery completed.
Authenticate again before issuing session-dependent commands if necessary.

This is local traffic scheduling, not a logout endpoint or a guarantee against
server-side inactivity, attacks, or session takeover. The server may retain a
session after local silence begins. Other processes, devices, and clients are
outside this tool's control. Offline tests cannot establish server-side protection.

## Contributing

Any suggestions are welcome, just open an issue on Github. If you want to contribute to the source code, you can fork this repository and submit a pull request.

## License
See the [LICENSE](LICENSE) file
