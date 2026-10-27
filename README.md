# Trickster Arts Hackers reverse engineering
![GitHub](https://img.shields.io/github/license/Mario-jesus/ta-hackers-client)
[![Tests](https://github.com/Mario-jesus/ta-hackers-client/actions/workflows/tests.yml/badge.svg)](https://github.com/Mario-jesus/ta-hackers-client/actions/workflows/tests.yml)

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
git clone https://github.com/Mario-jesus/ta-hackers-client.git
cd ta-hackers-client
# Use Ruby 3.3.12 and Bundler 2.5.22.
export BUNDLE_PATH="$PWD/.bundle/native-readline"
export BUNDLE_APP_CONFIG="$PWD/.bundle"
export BUNDLE_FROZEN=true
bundle _2.5.22_ install
export RUBYLIB=$PWD/lib
```

Before interactive use, [build the native callback with GNU Readline 8.3](docs/cli-interactive-chat.md#reproducible-native-build-and-tests).
The ignored native artifact is not delivered by Git: rebuild it after pulling
native source changes or changing Ruby/toolchains. Batch/non-TTY use does not
load this editor.

Next, [configure an account](#account-configuration) before connecting.

## Account configuration

Configuration files contain JSON, even though their extension is `.conf`.
`configs/default.conf` is the public template: its `id: 0` and empty `password`
are placeholders, not usable credentials. The default platform is `apple`.
Keep the server settings from the template unless you know they must change.

### Create a new account

To create a new game account and automatically save its ID and password in
`configs/my.conf`, run this from the repository root:

```bash
bundle exec ruby bin/sandbox -n my
chmod 600 configs/my.conf
```

This contacts the server and creates a real account; do not use it merely to
open an existing account. It copies the default settings and refuses to overwrite
an existing configuration with the same name.

Alternatively, the sandbox command `new` creates an account and **prints** its
ID, password, and session ID:

```text
new
```

Unlike `-n my`, `new` does not save a configuration or switch the running session
to the new account. Save the returned **ID and Password** in a private config as
described below, then restart with that config. A session ID is temporary and
does not replace those credentials.

### Link an existing account with `cpuse`

Use a platform-change code belonging to an account you own. An already
authenticated client can generate one with `cpgen`. Treat the code as a secret.
`cpuse` requires a connected sandbox session; it cannot run against the empty
default credentials.

If you have no working sandbox account yet, create a temporary one first:

```bash
bundle exec ruby bin/sandbox -n bootstrap
chmod 600 configs/bootstrap.conf
bundle exec ruby bin/sandbox -a -m -c bootstrap
```

At the sandbox prompt, connect and redeem your code for the target platform:

```text
connect
cpuse YOUR_PLATFORM_CHANGE_CODE apple
```

Replace `YOUR_PLATFORM_CHANGE_CODE` with your actual code. `cpuse` calls the
platform-change API and prints the linked account's **ID and Password**; it does
not write them to disk or replace the current session. Save those returned
credentials in a separate configuration, rather than the bootstrap account's
credentials. The platform argument must match the target configuration.

### Save credentials and select the configuration

For example, create `configs/apple.conf` from the public template **only if that
file does not already exist**:

```bash
cp -n configs/default.conf configs/apple.conf
chmod 600 configs/apple.conf
```

Edit `configs/apple.conf` with your preferred text editor. Replace `id` and
`password` with the values returned by `new` or `cpuse`, keeping valid JSON:

```json
{
  "id": 123456789,
  "password": "REPLACE_WITH_RETURNED_PASSWORD",
  "platform": "apple"
}
```

This is an excerpt, not a replacement for the whole template: preserve its other
settings. The ID above is only an example; use your returned numeric ID. Leave
`autocmd` empty if you want to connect manually.

Exit the old sandbox session and start a new one with the saved configuration:

```bash
bundle exec ruby bin/sandbox -a -m -c apple
```

Then enter `connect`. `-c apple` resolves to `configs/apple.conf`; `-a` disables
automatic configuration commands and `-m` uses minimal authentication.

**Keep credentials private.** Never put real credentials in the tracked
`configs/default.conf`, a README, an issue, or a screenshot. Private account
configs are ignored by Git, but ignore rules do not protect files already
tracked; never force-add credential files.

## Install and run on Termux (experimental)

Run these commands **inside Termux on Android**, not on your desktop. Keep the
checkout under Termux's home directory (`$HOME`), rather than shared storage such
as `/sdcard`. The desktop `mise` launcher and `env-ruby33.sh` are not required.

**Compatibility:** the reference toolchain is Ruby 3.3.12 with GNU Readline 8.3.
Termux may provide a different Ruby version, and these instructions have not been
validated on Android. The interactive editor still requires GNU Readline 8.3;
do not remove its version check to work around a load error.

### 1. Install system tools and Ruby dependencies

```bash
pkg update
pkg upgrade
pkg install git ruby clang make pkg-config readline
gem install bundler --no-document
```

If you already cloned the repository into `~/ta-hackers-client`, enter it directly.
Otherwise, clone it first:

```bash
git clone https://github.com/Mario-jesus/ta-hackers-client.git "$HOME/ta-hackers-client"
cd ~/ta-hackers-client
```

From the repository root, install the gems:

```bash
unset BUNDLE_FROZEN BUNDLE_DEPLOYMENT
bundle update --bundler
bundle add base64 readline net-http
bundle install
```

This updates your local `Gemfile` and `Gemfile.lock`: newer Ruby releases may no
longer provide these libraries implicitly. It is a Termux setup adjustment, not
the frozen reference-toolchain installation described above.

### 2. Build and verify the native terminal editor

The native artifact is not included in Git and must be built on the phone. The
project's build helper requires Ruby 3.3.12; for the experimental Termux runtime,
configure and compile the extension directly in its ignored build directory:

```bash
mkdir -p .bundle/native-readline-callback
cp ext/cli_readline_callback/extconf.rb \
   ext/cli_readline_callback/cli_readline_callback.c \
   .bundle/native-readline-callback/

(
  cd .bundle/native-readline-callback &&
  ruby extconf.rb --with-readline-dir="$PREFIX" &&
  make
)
```

Verify the editor without connecting to the game:

```bash
bundle exec ruby -Ilib -rsandbox -rcli/interactive_shell \
  -e 'Sandbox::InteractiveShell.load_native; puts "Native editor OK"'
```

Continue only if this prints `Native editor OK`. If compilation or loading fails,
retain the error and check `ruby -v` and the installed Readline version before
proceeding. Rebuild after changing Ruby or pulling native source changes. A
successful load is not proof of full Android terminal compatibility.

### 3. Start with an existing account

For a configuration named `apple`, securely copy your existing account file to
`configs/apple.conf` if it is not already present. Cloning the repository does
not guarantee that your private credentials are included. Do not publish them.
If you do not have a configuration yet, follow [Account configuration](#account-configuration)
to create an account with `new` or link one with `cpuse` and save its credentials.

```bash
ls configs/apple.conf
chmod 600 configs/apple.conf
bundle exec ruby bin/sandbox -a -m -c apple
```

At the sandbox prompt, connect explicitly:

```text
connect
```

`-a` disables automatic configuration commands, `-m` selects minimal
authentication, and `-c apple` loads `configs/apple.conf`. This uses the existing
account; it does not create a new one. On subsequent launches, run the same
`bundle exec ruby bin/sandbox -a -m -c apple` command from the repository root.

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
Retry waits stop at that deadline and transition directly into scheduled silence
without reopening traffic. An in-flight recovery that finishes after the deadline
also enters silence immediately; post-silence retries restart at 10 seconds.
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
