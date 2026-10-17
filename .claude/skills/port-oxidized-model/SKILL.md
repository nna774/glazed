---
name: port-oxidized-model
description: Port an Oxidized model (lib/oxidized/model/*.rb) to a native glazed dialect under glazed/lib/glazed/dialects, with a device simulation fixture, golden files, secret redaction patterns, NOTICE/README/CHANGELOG updates. Use whenever the user asks to port, convert, add or "nativise" an oxidized model or a network device dialect (ios, junos, aireos, eos, fortios, routeros, ...) to glazed, or reports a secret leak, pager stall or login problem in an existing native dialect, even if they do not say "port" or "native".
---

# Porting an Oxidized model to a glazed dialect

glazed has native dialects (`ios`, `junos`, `aireos`, `awplus`, `nec_ix`) and a shim (`glazed-oxidized`, dialect `oxidized_<model>`) that runs any Oxidized model unmodified. A native port is worth it when the user wants proper secret redaction (the shim only derives patterns from `cmd :secret`), a clean dialect to maintain, or both. If the user only needs the device to work, point them at `oxidized_<model>` first (docs/oxidized-shim.md).

Read `docs/dialect-api.md` and one or two existing dialects before writing. `nec_ix.rb` is the smallest; `ios.rb` shows `raw` steps, params, secrets and helper methods; `aireos.rb` shows in-session login and pager handling; `junos.rb` shows exec transport and `run.vars`.

## Inputs

- Reference Oxidized checkout: `~/git/github.com/ytti/oxidized` (never install gems into it or modify it).
- Vendored, unmodified copies live in `third_party/oxidized`; do not edit those.
- Real device output, if the user gives a path (a backup file, a `tmp/redacted/*` output, a hardware host). Real output is the best source for secret patterns. Its secrets may be stale and safe to read, but never copy real values into the repo.

## Workflow

1. **Read the model** in `lib/oxidized/model/<name>.rb` and note its `prompt`, `comment`, `expect`, `cmd` blocks (`cmd :all`, `cmd :secret`, `cmd 'show ...'`), `cfg :ssh/:telnet` blocks, `vars(...)` use and `cut_head/cut_tail/cut_both`.
2. **Check for existing simulations**: `ls ~/git/github.com/ytti/oxidized/spec/model/data/<name>:*`. Oxidized's own `<model>:<capture>:simulation.yaml` files are real device captures; reuse them instead of inventing output.
3. **Translate** (table below), write the dialect.
4. **Build the fixture and golden files** (below).
5. **Compare with real Oxidized** when a simulation exists (below).
6. **Update the surrounding files** (checklist at the end), run the checks, then stop. Commit only when asked.

## Translation

| Oxidized | glazed dialect |
|---|---|
| `prompt /re/` | `prompt(/re/)`; keep the model's regexp, it was tuned on real devices |
| `comment '! '` | `comment_prefix '! '` |
| `expect /--More--/ do ... send ' ' ...` | `interact(/--More--/) { \|cli, _buffer, match\| cli.write(' '); Actions::Replace.new(content: match.pre_match + match.post_match) }`. The responder must remove the pattern from the buffer or it fires forever |
| `cmd 'show x' { \|cfg\| ... }` | `book.command('show x') { ... }`; the block's return is emitted. Add `comment(...)` where the model had `comment cfg`. No block means the output is appended as is |
| `cmd :all` | `filter_output { ... }` |
| model logic needing several commands, `vars`, or conditionals | `book.raw('desc') { \|run\| run.command(...); run.emit(...) }` with `run.param`, `run.secret`, `run.vars` |
| `cut_head`, `cut_tail`, `cut_both` | the echoed command line and trailing prompt are already removed from `result.output` (`CliSession#command`), so drop the trims that only removed those; keep trims of other lines (banners, `Building configuration...`) and confirm in the golden file. Oxidized's `[3..-2]` style slices usually count the echo and prompt |
| `cmd :secret { \|cfg\| cfg.gsub!(...) }` | one `sensitive_pattern(/.../) { it[1] }` per substitution, naming only the secret (see Secrets) |
| `cfg :telnet { username /re/; password /re/ }` | `communication :telnet { \|c\| c.username_prompt = /re/; c.password_prompt = /re/ }` |
| `cfg :ssh { exec true }` | `communication :ssh { \|c\| c.exec = true }` |
| `post_login`, `pre_logout` | `config.post_login { \|run\| run.cli.command(...) }`, `config.pre_logout { \|run\| run.cli.write("exit\n") }` |
| `vars :enable`, `vars :foo` | `run.secret('enable')` for credentials, `run.param('foo')` for flags. Params are strings, so compare with `== 'true'`. Name model-specific params with the dialect prefix (`ios_rbac`, `junos_license`) |
| `Oxidized::Model` subclass (e.g. `IOSXE < IOS`) | `class IosXe < Ios`; declarations accumulate, prompt/comment/runbooks replace |

Naming: the dialect is named after the OS, matching Oxidized's model name (`wlc` was renamed to `aireos` because it was ambiguous with IOS-XE 9800 controllers). The file is `snake_case.rb` and the class `PascalCase` (`necix` becomes `nec_ix`/`NecIx`).

Logins are the common source of device-specific trouble, so decide deliberately:
- Telnet: set `username_prompt`/`password_prompt`.
- SSH: leave them unset when the device authenticates at the SSH layer. Set them only if the device asks for credentials again inside the session (old AireOS does, newer does not); the collector answers whichever prompt appears first and goes straight on if the CLI prompt shows up, so declaring them is safe either way.
- Enable: send it in `post_login` using the node's `enable` secret, falling back to a bare `enable` when param `enable` is `'true'`, as `ios.rb` does.
- Pagers: disable with a command in `post_login` (`terminal length 0`), and also add an `interact` for the pager prompt when you have seen a device ignore the command (AireOS prints `--More-- or (q)uit` for `show run-config commands` even after `config paging disable`).
- Non-UTF-8 devices: convert in `filter_output` (see docs/dialect-api.md, Encoding). Collected text must be UTF-8 or the node fails.

## Secrets

This is where ports go wrong, and the user has already caught two leaks after the fact. glazed publishes a redacted copy of every configuration, so an unmatched secret is a published secret.

- Oxidized's `cmd :secret` is a starting point, not the answer. Some models have none at all (`necix` has no `cmd :secret`), and others only cover plaintext forms. Derive patterns from the device's command reference and, better, real configuration output.
- Every pattern uses a capture group around the secret only, so the rest of the line survives in diffs: `sensitive_pattern(/^enable secret \d (\S+)/) { it[1] }`. Patterns run against the whole text, so `^` is a line start and multiline patterns work.
- Cover every form of a secret: plaintext, hashed/typed (`password 7 xxxx`, `secret 5 ...`), encrypted blobs, and keys that follow a type number. A regexp that treats the type number as the secret leaves the credential in the clear (this happened with NEC IX `authentication secret-password 1 <secret>`).
- Prefer one generic pattern for a recognizable encrypted format (AireOS `1 <iv> <hmac> [<len>] <ciphertext>`) so commands you did not list are still covered, plus specific patterns for plaintext forms.
- A device may print lines with or without a prefix. AireOS `show run-config commands` printed lines without the leading `config `, so every `^config ...` pattern silently matched nothing. Write `^(?:config )?...` when a prefix is optional, and put a fixture line for each shape.
- SNMP community names are secrets and sit on many line types (`community`, `accessmode ro <name>`, `ipaddr`, trap hosts). Search the whole configuration for them, not only the `community` line.
- Don't redact placeholders that are literal text (`$password`) or values that are not secret (an authority id that is just "Cisco" in hex); say so in the final report.
- After writing patterns, run them over any real output the user gave you and grep what is left: long hex strings, `password`, `secret`, `key`, `community`, `psk`, `auth`. Report coverage as counts, and say plainly what you could not verify against a live device.

## Fixture and golden files

Specs replay a device session through the real `Collector` and `Redactor` using `spec/support/dialect_simulation.rb`. Files live in `glazed/spec/fixtures/dialects/<dialect>/`:

- `<capture>.yaml`: the simulation.
- `<capture>.collected.txt`: expected collected configuration.
- `<capture>.redacted.txt`: expected redacted configuration.

Two ways to write the yaml:

1. **Reuse an Oxidized capture**: the whole file is `oxidized: <model>:<capture>` (see `ios/asr920_16.8.1b.yaml`). The simulation itself is read from `third_party/oxidized/spec/model/data/`. If the capture is missing there, copy the file from the Oxidized checkout unmodified, and record the commit it came from in `third_party/oxidized/README.md` and the NOTICE files if it differs (see Licensing and credit). Add a `secrets:` list to the yaml if you want the leak check; the key merges over the Oxidized data.
2. **Hand-written**: `init_prompt`, `commands` (each value is the raw response including the echoed command and trailing prompt, `\x20`-style escapes allowed) and `secrets` (every secret value that must not survive redaction). Start the file with a comment that says whether it is a capture or hand-written. Use random values (`SecureRandom`) and documentation address ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24). Never put real secrets, serials or hostnames from a user's backup in the repo; copy only the line shapes.

Add a fixture variation for each behavior you handle: a controller that authenticates at the SSH layer, a pager that ignores the disable command, lines with and without a prefix, an `enable` login. Each gets its own capture name.

Spec file `glazed/spec/glazed/dialects/<dialect>_spec.rb`:

```ruby
# frozen_string_literal: true

# SPDX-License-Identifier: Apache-2.0

require 'glazed/dialects/<dialect>'

RSpec.describe Glazed::Dialects::<Class> do
  it_behaves_like 'a dialect simulation', '<dialect>/<capture>', transport: 'ssh'
end
```

Use `exec: true` for exec-channel dialects and `node_secrets: {'enable' => ...}` when a login secret is needed. Add targeted examples (see `ios_spec.rb`, `aireos_spec.rb`) for hooks and params: assert on `device.instances.first.written` for what was sent at login/logout, and use `FakeTransport.device(greeting:, responses:)` for scripted sessions. Unknown commands raise in `FakeTransport`, so a spec that omits a command proves the dialect does not send it.

Generate goldens, then review them by eye, since a golden written from wrong output passes forever:

```
cd glazed && GLAZED_UPDATE_GOLDEN=1 bundle exec rspec spec/glazed/dialects/<dialect>_spec.rb
git diff -- spec/fixtures
```

Check the redacted file for anything that still looks like a secret, and the collected file for volatile lines (timestamps, uptime, counters) that would make every backup differ. Strip those in the runbook block, as `nec_ix` drops `Current time` and `ios` drops `ntp clock-period`.

## Compare with real Oxidized

When Oxidized has a simulation for the model, its expected output is the reference. Install Oxidized into an isolated bundle under `tmp/` (a Gemfile with `gem 'oxidized', path: '~/git/github.com/ytti/oxidized'` and `gem 'logger'`, `BUNDLE_PATH=vendor/bundle`), run the simulation as `spec/model/model_helper.rb` does, and diff against `<capture>.collected.txt`. Differences should be understood and intended: trailing spaces, CRLF normalization (glazed's `Base` normalizes it), and secret removal. Differences found this way for `ios` were SNMPv3 host lines (carry a user name, not a community) and mgmtuser secrets with spaces; record such deliberate divergences in the commit message.

## Hardware check

If the user offers a device (see the `hardware-test-devices` memory), run the dialect against it with a small glazed config and read the redacted output. The first real run tends to surface login and timeout issues: silent periods while the device builds output (the collector's timeout is a silence timeout), pagers, SSH keepalives. Say clearly which parts were never run against a device.

## Files to update

1. `glazed/lib/glazed/dialects/<dialect>.rb`: starts with `# typed: strict`, `# frozen_string_literal: true`, the SPDX line, then this attribution (adjust file name):

   ```ruby
   # Derived from Oxidized (https://github.com/ytti/oxidized) lib/oxidized/model/<model>.rb,
   # Copyright 2013-2015 Saku Ytti, Samer Abdel-Hafez and Oxidized contributors,
   # licensed under the Apache License, Version 2.0. Modified for the glazed dialect API.
   ```

   Follow the repo conventions: YARD doc on the class (and on helper methods) stating the device family, node params and secrets it reads; inline RBS `#:` signatures on helper methods; comments only for why (external constraints, device quirks), short, no change narration.
2. Spec and fixtures as above.
3. `glazed/spec/glazed/dialects_spec.rb`: add the name to the `%w[aireos awplus ios junos nec_ix]` list.
4. `README.md` (Supported devices table; node `params`/`secrets` mentions if you added any) and the dialect list in `glazed/README.md` if present.
5. `NOTICE` and `glazed/NOTICE`: add the dialect to the "ported from" file list and the model name to `lib/oxidized/model/{...}.rb`.
6. `glazed/CHANGELOG.md`: a line under `[Unreleased]`. Renaming a released dialect is a breaking change and must say so.
7. Run from the repo root and fix everything before reporting: `cd glazed && bundle exec rspec`, `bundle exec srb tc`, `bundle exec rubocop`, `bin/check-docs`. The commit hook (`hk`) enforces rubocop, SPDX headers, sorbet and YARD, and fixtures are excluded from linting.

Do not run `bin/tapioca` or touch `glazed/lib/glazed/v1` unless protos changed (they did not).

## Licensing and credit

Oxidized is Apache-2.0, and glazed redistributes parts of it, so a port must stay legitimately derived.

- Record the Oxidized commit each port was made from; there is no requirement to stay on one commit. `third_party/oxidized/README.md` and the NOTICE files state the commit the vendored files come from (currently `d7f51c2`). Take `git -C ~/git/github.com/ytti/oxidized rev-parse HEAD` when porting. If it differs from the recorded one, update the recorded commit in those places in the same change, and make sure every file in `third_party` really is from the commit it names (recopy older ones from the new commit). Do not leave files from different commits under one stated commit.
- `third_party/oxidized` holds unmodified Oxidized files at their original repo paths (`spec/model/data/<model>:<capture>:simulation.yaml`, `lib/oxidized/model/<model>.rb`), under the `LICENSE` already there. Copy with `cp`, never edit them, and list new kinds of files in its README.
- A dialect file that draws on a model carries the attribution header shown above. When the model `require_relative`s a parent, the dialects derived from each upstream file carry it.
- In `NOTICE` and `glazed/NOTICE`, list the dialect and the model it was ported from. Also list fixtures derived from Oxidized: a yaml that adds commands to an Oxidized simulation, and the `.collected.txt`/`.redacted.txt` generated from it. Hand-written fixtures are not derived and are not listed.
- A yaml that only says `oxidized: <model>:<capture>` copies nothing, so it needs no separate credit beyond the golden files generated from the capture.
- Keep Oxidized's copyright lines as they are (Saku Ytti, Samer Abdel-Hafez and Oxidized contributors). Do not add glazed's author to the derived-from line.

## Reporting

Be specific and honest in the summary: what the dialect covers, what fixtures are captures versus hand-written, what was checked against real output (with counts), and what has not been run against a live device. The user asks "is this dummy data?" when it is not stated, so state it.

## Commits

Only commit when asked. Use `/sorah-guides:commit`; one self-contained commit per dialect (dialect, spec, fixtures, docs together), subject like `dialects: Cisco IOS` or `Aireos: redact secrets without the config prefix`. A follow-up fix to a single dialect is a separate commit titled `<Class>: <what changed>`. Check `git branch --show-current` first and ask if it is the default branch. If signing fails with `Inappropriate ioctl for device`, ask the user to unlock their GPG key rather than skipping signing.
