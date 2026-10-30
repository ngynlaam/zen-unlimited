# CONTEXT.md

Glossary for this repo. Use these terms exactly.

- **rotate**: change egress by reconnect of WARP. A daemon action. Never means resend of a request.
- **retry**: resend of a failed request. A client action. Never means change of egress.
- **rotate-signal**: one 429 or rate-limit event seen by the daemon. It asks for a rotate. It is not a retry.
- **park**: a timed pause of rotates after a stuck edge or a quota window. It slows rotation. It never stops the daemon.
- **stuck edge**: a rotate that leaves the egress edge unchanged. It means the rotate bought nothing.
- **quota window**: a run of 429s that rotation does not clear. It calls for a park, not more rotates.
