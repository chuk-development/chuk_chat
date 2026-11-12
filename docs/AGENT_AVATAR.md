# Agent avatar (the round figure)

Every agent face is `AgentAvatar` (`lib/ui/agent_avatar/agent_avatar.dart`).
`AgentFace` and `ExpressiveFace` in `lib/ui/expressive/agent_face.dart` only
forward to it. A picture that the user set for the agent replaces the figure.

## The figure

- The round figure ("D1 rund"): a soft, rounded cube body (a faceted
  superellipsoid), ball arms, ball feet, and a big face (white eyes with
  pupils, cheeks, a mouth) drawn at its projected spot so it turns with the
  body. Nothing is on its head. The square cube is the second style
  (`paintCubeAvatar`). Code: `cube_figure.dart` (geometry, face, props, camera fit),
  `avatar_rig.dart` (states and poses), `avatar_engine.dart` (a small
  software 3D renderer: perspective, back-face culling, painter's sort,
  Lambert light from the top left, decals in face UV space).
- Colour: the hue of `agentAccent()`, the same colour as the agent's bubbles
  (`cubeBodyColor`).
- The camera is fitted once to the union of all poses (`fitPoses`). Every
  move stays inside a round or square frame of any size. The resting figure
  sits in the middle. Visual check with the real engine:
  `tool/agent_avatar_shot.dart` (see its header).
- To change the style, change `kAgentAvatarPainter`. A new style is one
  function with the same signature.

## States

| State | When | What it does |
|-------|------|--------------|
| work  | `AgentsAgent.running` | Uses a prop and changes it every 7 s (laptop, letter, book, palette, binoculars). The role has no effect. |
| done  | a running turn just stopped | One cheer jump (1.7 s). |
| sleep | no activity for 6 h (`kAgentSleepAfter`) | Tips onto its side, eyes shut, a small Zzz in the corner (not below 40 px). |
| idle  | otherwise | Breathes, blinks. |

Only one avatar follows the pointer: the agent whose row is under the
pointer, else the open agent. The shell sets
`AgentAvatarFocus.openAgentId` in `agents_shell_state.dart`. The pointer
comes from one global `pointerRouter` route. The row is the nearest
`ListTile` / `InkWell` ancestor.

## Cost

- Each pose is drawn once into an offscreen image at device pixels
  (`toImageSync`) and then drawn 1:1. A still avatar costs one image draw.
  Impeller has no raster cache. Without the image, it rasters every visible
  avatar again on every frame.
- The ticker runs only while something moves: work, the cheer, a state
  blend, a blink, the followed avatar settling. A still list requests no
  frames. Sleep redraws its Zzz 5 times a second on a timer. At 32 px or
  less, only the blink moves. Avatars that do not follow the pointer draw
  their loops at 30 fps. `TickerMode` and reduced motion are respected.
  Under `flutter test` the motion is off (`agentAvatarMotion`).
- Measured on 2026-11-12, profile build, 100 agents in a lazy list (27
  mounted, 7 ticking): UI thread p50 0.7 ms / p99 2.4 ms. Raster p50
  0.75 ms / p99 2.2 ms (Xvfb, software GL). No frames over 16.7 ms.
  Before the offscreen image: raster p50 16.3 ms, 226 slow frames.
  Harness: `xvfb-run -a flutter run --profile -d linux -t tool/agent_avatar_perf.dart`.

## Impeller on Linux: jagged path edges

Impeller makes path edges smooth only with MSAA. The on-screen GL surface on
Linux has one sample per pixel (`impeller/renderer/backend/gles/surface_gles.cc`,
`SampleCount::kCount1`). For this reason, every path that is drawn directly on
the screen has stair-step edges. Offscreen targets (`saveLayer`,
`toImage`/`toImageSync`) get 4x MSAA on GLES 3 (`capabilities_gles.cc`).
The avatar draws offscreen for this reason. The same problem applies to all
other paths in the app on Linux.
