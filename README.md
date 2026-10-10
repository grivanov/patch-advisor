# patch-advisor
A read-only AI auditor for a server. On each run, Claude Code checks which OS packages and Docker images on the host have newer versions, reads the upstream release notes and changelogs, classifies every update (security, breaking, urgent, routine).
