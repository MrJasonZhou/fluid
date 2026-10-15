# Providers

Fluid keeps a usage window open and tells you when it cannot. Neither
job is specific to one coding agent: several meter a subscription the same
way, and the parts that differ are small and well separated.

A provider is one shell file under `providers/`, installed to
`~/.fluid/providers/<id>.sh`. It answers a handful of questions
about one agent. Everything else — scheduling, the anchor, alerts, stall
detection, install and uninstall — is shared and knows nothing about any
particular agent.

## What the core needs

The core thinks in terms of one **short window** and one **long window**:

| Field | Meaning |
|---|---|
| `window_seconds` | how long a short window lasts |
| `used_percent` | how much of the current short window is spent |
| `resets_at` | epoch second the short window resets |
| `long_used_percent` | how much of the long window is spent, if there is one |
| `long_resets_at` | epoch second the long window resets, if there is one |

Each is a plain number. A reading that has `used_percent` or `resets_at`
describes the whole picture: a long window it leaves out is taken to be gone,
and the stored one is dropped. A reading with neither (nothing used yet this
session) leaves what is stored alone.

Everything else is the provider's business.

## Contract

Each file defines functions prefixed with its id. `<id>_label`,
`<id>_available`, `<id>_capabilities` and `<id>_parse_limits` are required;
the rest have defaults.

| Function | In | Out |
|---|---|---|
| `<id>_label` | — | a human name, e.g. `Claude Code` |
| `<id>_available` | — | exit 0 when the agent is installed here |
| `<id>_capabilities` | — | space-separated: `keep`, `alert` |
| `<id>_parse_limits` | the agent's own JSON on stdin | the fields above as JSON, omitting what it does not know |
| `<id>_warmup` | a model id, possibly empty | runs the smallest possible request; output on stdout, exit code decides |
| `<id>_cheap_model` | — | the cheapest model worth warming up with; empty to let the agent choose |
| `<id>_auth_failed` | warmup output on stdin | exit 0 only when the login is really gone and someone must sign in again |
| `<id>_unknown_model` | warmup output on stdin | exit 0 when the failure is a model the agent no longer knows |
| `<id>_pull_limits` | — | the agent's own JSON, for agents that cannot push (see below) |

### Capabilities

`keep` means the agent meters a **quota** in a short window that starts at the
first request: quota left when the window resets is wasted, so opening a window
early is worth something. `alert` means only that failures are worth reporting.

Not every agent earns `keep`. A short window that rate-limits *requests* rather
than metering quota (Kimi Code) wastes nothing when it goes unused, and an
agent with one shared weekly pool and no short window (Grok Build) has no
window to keep open. Those providers declare `alert` alone, and the core never
schedules a warmup for them.

Resuming a session stopped on a usage limit is not part of the contract. It
needs to be inside the agent: for Claude Code the plugin's hooks module does it
(`hooks/register.ts`), and the core only logs and alerts for it through
`fluid.sh log` and `fluid.sh notify`.

### Telling a dead login from a bad minute

`<id>_auth_failed` decides whether a human is woken up, so it must match only
the wording an agent uses for a login that is actually gone. Agents have
separate wording for a token refresh that failed this once, or that lost a
cross-process lock to another instance of the same agent; both come back on
their own and belong in the ordinary retry path. The core helps either way: it
rechecks an hour later and reports nothing unless that recheck fails too.

### The warmup model

A warmup should be the cheapest request the agent will accept, which usually
means naming a small model. Model ids are not forever, so the core never
trusts one: when a warmup fails and `<id>_unknown_model` recognises the
output, it drops to whatever the agent picks for itself, remembers that in
`state/<id>/warmup_model` and says so once. Both functions have defaults —
no model, and a general "does not exist" pattern — so a provider whose agent
takes no `--model` need not define either.

### Push and pull

Some agents run a command of your choosing on every status line refresh, and
will hand over their limits for free. Those are **push**: the observer wraps
the agent's status line, and every refresh hands its JSON to `fluid.sh observe
<id>`, in the background so the status line never waits for it. Claude Code
pushes too, but from the plugin's hooks module rather than a wrapper, so its
settings are never edited: the module calls `fluid.sh observe claude mod` with
the same JSON its status line would get.

Others only write their limits to a session log. Those are **pull**: the core
calls `<id>_pull_limits` when it needs a reading, typically just before a
warmup. A pull provider sees limits less often, which only costs precision in
the estimate of the next reset.

## Adding one

1. Write `providers/<id>.sh` with the functions above.
2. Add an observer to the installer if the agent can push: one function to
   install the hook, one to take it out. Both edit the agent's own config and
   must leave everything else in it alone — see how `STRIP_FILTER` does it.
3. Add a case to `tests/run.sh` with a fake agent CLI.

No core file needs to know the id exists: providers are discovered by listing
the directory.

## State

Each provider gets `state/<id>/`, so their windows, schedules and alert flags
never mix. One queued run per provider: an `at` job, or a launchd agent on
macOS. The anchor is shared, since it is about
the user's day rather than any one agent.
