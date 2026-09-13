# Session input baseline

Native Start lists matching inputs and establishes a streaming SHA-256 baseline
off the main actor before presenting the existing-input question. Progress and
Cancel remain available. Cancellation retires the request immediately; chunked
reads check cancellation, though an OS read stalled on a share may return later.
Late results cannot reopen the question or start a session.

This deliberately reads all pre-existing input bytes once, even if the operator
subsequently selects Stack existing + new. A 500-sub / 26 GB folder therefore
still costs a 26 GB baseline pass. No claim of zero-I/O startup is made. Without
the old content digest, a later digest cannot distinguish identical replacement
from a genuinely changed capture.

Baseline reads use one descriptor, check the recorded stat identity before and
after hashing, and recheck the path. A failure or change during that file's read
fails Start with an actionable message. Files not in the initial listing remain
new; a file changed after its successful baseline read also remains new unless
the watcher proves its bytes identical.

New arrivals only excludes unchanged identities before watcher content validation
or hashing. Identity churn takes the watcher digest path and compares full content
against the baseline for the same name and size. Same-size changed content is
not excluded. The cheap path retains the native watcher's immutable-publication
assumption: a write preserving every stat field is not detected by stat alone.

Exclusions are reported once per baseline name, across polls and folder re-arms,
and contribute to source admission/exclusion totals even when no frame is decoded.
The Start log describes policy, not a count already processed. Original files
are not deleted. Non-excluded updates retain the shutdown accounting barrier.

The pending question and baseline both own the selected input, so late relay
detection cannot redirect them. Accepted and rejected frames clear the waiting
banner only for the currently bound presentation. Shutdown uses one saturating
deadline: positive infinity means no deadline; NaN/non-positive budgets grant no
extra time, and finite budgets are not renewed between watcher and relay waits.
