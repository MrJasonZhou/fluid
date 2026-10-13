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

Everything else is the provider's business.

## Contract

Each file defines functions prefixed with its id. `<id>_label`,
`<id>_available`, `<id>_capabilities` and `<id>_parse_limits` are required;
the rest have defaults.

| Function | In | Out |
|---|---|---|
| `<id>_label` | — | a human name, e.g. `Claude Code` |
| `<id>_available` | — | exit 0 when the agent is installed here |
| `<id>_capabilities` | — | space-separated: `keep`, `alert`, `resume` |
| `<id>_parse_limits` | the agent's own JSON on stdin | the fields above as JSON, omitting what it does not know |
| `<id>_warmup` | a model id, possibly empty | runs the smallest possible request; output on stdout, exit code decides |
| `<id>_cheap_model` | — | the cheapest model worth warming up with; empty to let the agent choose |
| `<id>_auth_failed` | warmup output on stdin | exit 0 only when the login is really gone and someone must sign in again |
| `<id>_unknown_model` | warmup output on stdin | exit 0 when the failure is a model the agent no longer knows |
| `<id>_pull_limits` | — | the agent's own JSON, for agents that cannot push (see below) |
| `<id>_stuck` | a session transcript path | exit 0 when that session is still stopped on a usage limit and nobody has continued or cancelled it |

### Capabilities

`keep` means the agent meters a **quota** in a short window that starts at the
first request: quota left when the window resets is wasted, so opening a window
early is worth something. `alert` means only that failures are worth reporting.

Not every agent earns `keep`. A short window that rate-limits *requests* rather
than metering quota (Kimi Code) wastes nothing when it goes unused, and an
agent with one shared weekly pool and no short window (Grok Build) has no
window to keep open. Those providers declare `alert` alone, and the core never
schedules a warmup for them.

`resume` means the agent reports a turn that stopped on a usage limit (for
Claude Code, a `StopFailure` hook calling `fluid.sh rate-limit <id>`)
and `<id>_stuck` can read a session's transcript. The agent's own automatic
continue always goes first: the core looks again `RESUME_GRACE` seconds after
the reset and types `continue` into the session's tmux pane only if `stuck`
still says so and the pane still runs the same process.

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
will hand over their limits for free. Those are **push**: the observer installs
a hook that pipes the agent's JSON into `fluid.sh observe <id>`.

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
never mix. One `at` job per provider. The anchor is shared, since it is about
the user's day rather than any one agent.
