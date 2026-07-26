# Try Demo Cancellation Design

## Goal

Close the Try Demo v1 limitation: ending or quitting a demo should stop the demo generator promptly instead of letting it finish all scheduled updates.

## Scope

- Add a cancellation predicate to `DemoStackGenerator.run`.
- Make `AppModel.startDemoSession()` pass `!Task.isCancelled`.
- Make `AppModel.endSession()` cancel the active demo task.
- Keep command-line `demo-stack` and `fakesiril` behavior unchanged.

## Non-goals

- No auto-end walkthrough.
- No progress UI for the generator.
- No OBS automation.
- No change to generated FITS content for uncancelled runs.

## Verification

- Red/green test: generator stops after cancellation predicate turns false.
- `swift test --filter DemoStackGeneratorTests`
- `swift run demo-stack /tmp/liveastro-demo-cancel-smoke --interval 0 --count 1`
- `swift build`
- `git diff --check`

