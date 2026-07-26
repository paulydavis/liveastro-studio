# In-App Try Demo v1 Design

## Goal

Make the **Try Demo** workflow row do something useful without requiring a telescope, capture app, or Terminal command.

## Scope

Enable the existing **Try Demo** row in `ControlView` and add an `AppModel.startDemoSession()` action that:

1. creates `~/Documents/LiveAstro/DemoInput`;
2. configures LiveAstro for external-stacker mode:
   - source mode: `.stackerOutput`;
   - file prefix: `live_stack`;
   - watch folder: the demo input folder;
   - target/profile fields: simple demo values;
3. starts a normal LiveAstro session watching that folder;
4. runs `DemoStackGenerator` in a detached background task with finite settings.

## User-facing behavior

- **Try Demo** is enabled when live workflows are enabled.
- The row subtitle says it starts a local sample stack stream.
- The row no longer shows "coming soon".
- Logs say where the demo input is and when the generator starts/finishes.
- The user still clicks **End Session** when they are done, just like a normal session.

## Accepted v1 limitation

The demo generator is finite and simple. If the user ends the session before all demo updates are written, the generator may finish writing `live_stack.fit` in the demo input folder. That file is harmless and can be overwritten by the next demo run.

## Non-goals

- No automatic End Session.
- No OBS automation.
- No cancellation UI.
- No bundled sample asset.
- No change to native stacking, watcher semantics, or replay generation.

## Verification

- `swift run demo-stack /tmp/liveastro-demo-stack-ui-smoke --interval 0 --count 1`
- `swift build`
- `git diff --check`

