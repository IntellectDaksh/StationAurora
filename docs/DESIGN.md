# Station Aurora — full context dump

Roblox game. Studio place title: **"Space Station Emergency"**. Single-player narrative emergency / psychological horror game set on a damaged orbital station. Pinnacle class project (Daksh / Uideas). Companion academic paper: `D:\Project X\Station-Aurora-Paper-v2.docx`. Walkthrough video: `D:\Project X\StationAuroraVideo\station_aurora_walkthrough.mp4`.

---

## 1. One-line pitch
You are the last crew member awake on Station Aurora. The power is dead, five crew are missing, and every night you dream of an emergency. The question is whether the emergency is real or a dream.

## 2. Story

**Setting.** Station Aurora, in orbit above Earth. Mission day 212. Six crew on the roster, one awake. The crew shuttle has missed check-in by 11 hours. Main power failed during the standby cycle.

**Player character.** Default operator name: **Sam Ortega** (the player can rename the operator in settings; `%s` in dialogue = operator name).

**AURA.** The station AI and your only companion. Calm, dry, slightly too cheerful in reality. In dreams it slips: it gives the wrong day ("Mission day 2-2-2-2--"), calls you **Okafor**, drops signal ("[SIGNAL LOST]"), and insists missing crew are "asleep in the pods".

**Missing crew** (named in dialogue and endings): Okafor, Reyes, Lindqvist, Mercer, Tanaka.

**The twist / theme.** Dream events leak into reality:
- The ship from Dream 2 is still outside on Day 2, and it is real (AURA confirms "not a sensor ghost").
- Day 2: Okafor's voice comes over comms, but he isn't aboard.
- Day 3: the ship transmits on the station's own crew channel. The water tank shows six people's worth of usage. A Day 214 intercom recording plays "happy mission day two-twelve".
- The final ending card hints the station has been silent for 3 years. The days may be looping (data pad log 1,096: "If you found all six, you already know what day it is").

Core theme: can you trust your own perception under isolation and stress? Later dreams copy reality's visual style, so the player has to rely on instruments, not looks.

## 3. Structure (3 mission days, 4 dreams)

Game flow (GameStateManager director):
`MainMenu → Intro → [Day N reality tasks → sleep → Dream(s) that night → DayEnd autosave] ×3 → Choice → Ending → Restart → MainMenu`

| Day | Mission day | Title | Main tasks | Night dreams |
|---|---|---|---|---|
| 1 | 212 | Standby cycle | Tutorial: torch (F), find + restart backup generator. Tasks (any order): calibrate life-support readout, file status report, review task board, fix water recycler. Then distress: send distress signal (keypad code **2417**), check reply ×2. Sleep. | Dream 1 + Dream 2 |
| 2 | 213 | Contact | Lock the contact from the observatory telescope, reroute recycler coolant, hail the ship, listen to comms (Okafor's voice). Optional: EVA dish repair, data pads. | Dream 3 |
| 3 | 214 | Threshold | Recalibrate hull sensors, reroute O2 lines, calibrate water recycler, review task board. Then **choice A**: answer the ship (comms transmit) OR pull the comms breaker (stay silent). | Dream 4 → Choice |

Each day starts at 06:40 with an AURA intro and a HUD day badge plus objective log. You can only sleep after all of that day's tasks are done ("Finish today's tasks first").

## 4. The four dreams

| # | Name | Trigger title | Location | Objectives | Resources on entry (O2 / Power / Hull) | O2 drain/s | Can fail | Exit scare |
|---|---|---|---|---|---|---|---|---|
| 1 | System Anomaly | SYSTEM ANOMALY DETECTED (klaxon) | Windows + radar | Check observation windows, radar sweep (tag 4 contacts), go back to quarters | 97 / 100 / 100 | 0.02 | No | Shadow figure |
| 2 | The Foreign Ship | ALL LIGHTS OFFLINE | Observatory | Lock the ship through the telescope | 95 / 15 / 100 | 0.02 | No | Flare |
| 3 | Power Down | MAIN BUS OFFLINE | Power grid | Reset breakers A, B, C (relay sequences length 3/4/5, 1 repair unit each). Then **knock choice**: go back to pod (AURA asks) OR find the knocking in the washroom (optional) | 90 / 0 / 75 | 0.05 | No | Jump scare |
| 4 | Cascading Failure | O2 CRITICAL // MULTIPLE FAULTS (all alarms) | Life support | Open O2 valves 1, 2, 3 (1 repair unit each, keep pressure out of the red) | 60 / 60 / 70 | 0.4 | **Yes** | Pass out → Choice |

Visual dream language (CameraEffects): per-dream colour grade, vignette, handheld shake, torch flicker in dreams 2–3, intensity rising from 1 to 4.

## 5. Choices and endings

**Choice A (Day 3):** Answer the ship (transmit) vs stay silent (pull comms breaker).
**Choice B (after Dream 4):** AURA: "I can't tell which of these is the dream." Pick **DREAM** (go back to sleep) or **REALITY** (stay awake).

| | Answered the ship | Stayed silent |
|---|---|---|
| **Dream** (sleep) | **THE LONG SLEEP**: warm galley, crew back, a dish finds you but you don't wake; frost over the pod; "Silent for 3 years. One heartbeat aboard." | **THE LONG SLEEP (silent)**: no one calling, empty chairs, "It will stay that way." |
| **Reality** (stay awake) | **WAKING HOURS**: relief vessel *Kestrel* answers; all five crew come through the hatch; "The ship was never a dream. It came back for you." | **WAKING HOURS (silent)**: a ship slides past and doesn't slow down; "To them, Aurora is just debris." |

**Extra ending lines** (from save flags):
- Knocked (went to look in Dream 3): "The knocking stopped the night you went to look."
- Complied (stayed in pod): "AURA thanks you for staying in the pod. It always will."
- All 6 data pads: "Log 1,096, unsigned: 'If you found all six, you already know what day it is.'"

**Game over:** O2 hits 0 (mainly in Dream 4) → GameOver state → Restart from checkpoint. Deaths are counted.

## 6. Optional content / easter eggs
- **EVA comms dish repair**: suit up at the airlock, zero-g flight, helmet O2 timer, fix the dish → "DishFixed" flag (AURA: "I'm hearing a carrier"), and it changes Day 3 dialogue.
- **Crew data pads** ×6, found where the crew lived; all 6 unlocks the extra ending line.
- **Rubber duck** (EVA find): "Lindqvist lost one on day 212. This day 212, I mean."
- **Knocking** in the washroom during Dream 3.
- **Gravity toggle**: spawn console (F) or upper-deck lever (E) switches gravity 100% ↔ 10%.

## 7. Mechanics and resources

**Station resources** (StationState, server-owned, per player):
| Resource | Default | Notes |
|---|---|---|
| Power | 100 | 0 = blackout; PowerDoors lock/unlock on `workspace.AuroraPower` |
| Oxygen | 98 | Drains 0.225/s in reality after the generator (full tank ≈ 3.5 min). Refill at O2 stations (Comms, Hydroponics, Quarters) |
| HullIntegrity | 100 | Damaged in dreams |
| RepairUnits | 12 | 6 needed for a clean run (3 breakers + 3 valves). Refilled only on Restart |
| MissionTime | 1500 s | Mission clock |
| CrewSafety | derived | 0.4·O2 + 0.25·Power + 0.25·Hull + 0.1·clock |

Day 1 task timer: 300 s.

**Minigames** (client `Minigames`): Generator lever timing, Breaker (repeat the relay sequence), LogReport (match live readings), TaskBoard (acknowledge lines), WaterGauge (hold to fill, release in the green), Transmit (tune carrier + keypad 2417), RadarSweep, Telescope (sweep + lock), Valve (turn, keep pressure out of the red), PipeRoute (connect inlet to outlet), Calibrate (needles/waveform), CargoSort. Each has a `minTime` anti-skip. All are playable with keyboard, gamepad or mouse/touch. Esc closes; reopen with the prompt.

## 8. Controls
| Action | Keyboard | Gamepad |
|---|---|---|
| Move | WASD | Left stick |
| Sprint | Left Shift | L3 |
| Interact | **E, single press** (holds removed, see §10) | — |
| Torch (battery-limited) | F | Y |
| Checklist | Tab | — |
| Guide trail preview (8 s) | G | — |
| Pause | Esc | — |
| Minigames | WASD/arrows + Space/Enter, digits for codes | Stick/D-pad + A, B closes |

## 9. Map
Two decks. Approximate positions (studs):
- **Upper deck:** Crew quarters / sleep pod (-43, 29, -5), backup generator (-30, 28, 10), life-support readout (-18, 29, -17), life-support valves (-106, 30, 0), observatory (-159, 33, -34).
- **Lower deck:** Comms (-30, 13, -90), radar (-15, 13, -60), observation windows (0, 18, -92), status log (-92, 13, -44), power grid (-94, 15, 5), hydroponics (-120, 14, 5), task board (-120, 13, -120), washroom / water recycler (-44, 16, -190).
- **Outside:** Earth model (-90, 55, 430), EVA geometry in `Workspace["Aurora EVA"]`, foreign ship off the west windows.

Objectives find geometry by **CollectionService tags** (`Objective_Generator`, `Task_StatusLog`, `Objective_Comms`, `Objective_PowerGrid`, `Objective_LifeSupport`, `Task_Recycler`, `SleepPod`, …).

## 10. Code architecture

**ServerScriptService**
- `AuroraBoot`: boots GameStateManager.
- `GameStateManager` (ModuleScript, ~50 KB): the only state owner. One Session per player, a director coroutine through the story, objectives (`self.active`, `Session:Complete(id)`), prompts, pause, save checkpoints, choice. QA hook: `GameStateManager.GetSession(player)`.
- `ObjectiveHandlers/*`: Generator, Tutorial, RealityTasks, DistressSignal, RadarCheck, ObservatoryCheck, PowerGridRepair, OxygenRepair, StoryProps. Contract: `onTriggered(session, def, prompt)` / `onClientComplete`.
- `StationSystems` (consoles, lights, alerts, holo table), `PowerDoors`, `GravityControl`, `EVA`, `ScareDirector` (timing of scares, visuals run on the client), `SaveSystem` (DataStore `StationAurora_v1`, memory-only in Studio without API access).
- `InstantPrompts` (**added 2026-11-25**): forces `HoldDuration = 0` on every ProximityPrompt, including runtime-created ones. Accessibility: a single E press, no hold.

**ReplicatedStorage.Modules**
- `GameStateEnum`: 11 states (MainMenu, Intro, Reality, EventTrigger, DreamLayer, Objectives, Choice, Ending, Restart, Pause, GameOver), plus Pausable / Ticking / FreeMovement sets.
- `DreamEvents`: all story data (objectives, days, dreams, endings, intro, keypad code).
- `Beats`: all AURA dialogue and hint cards.
- `StationState`: resource model.
- `Cinematics`: cinematic registry (durations, skippable).

**Remotes:** StateChanged, StationState_Changed, PlayCue, RequestAction (Start / Continue / Pause / Resume / SkipIntro / Restart / SaveSettings), RequestChoice (Dream / Reality), RequestObjectiveComplete.

**StarterPlayerScripts (client)**
- `HUDController` (~117 KB): all UI built from code (menu, HUD, prompts, dialogue, waypoints).
- `Minigames` (~100 KB), `Cinematics` (camera director, letterbox, captions), `CameraEffects` (dream grades, scares, shake), `MusicDirector` (state-aware score, 3 s crossfades, ducks under dialogue), `PlayerKit` (torch, sprint), `GuideTrail`, `EVAClient`, `BlurGuard`.
- `ReplicatedFirst.LoadingScreen`: custom loader.

**Design system:** GothamSSm text, RobotoMono for numbers, near-black surfaces, one cyan accent (90, 200, 255), red only for critical states (O2 < 30, signal lost, wrong code).

## 11. Audit history (fixed)
- 785 unions switched to PreciseConvexDecomposition, and 33 overhead transparent parts made non-collidable (removed invisible barriers).
- Observatory outer wall added; floating room signs snapped to walls.
- Dream 3 cinematic camera moved out of geometry.
- Dream 4 oxygen rebalanced so it is fair.
- Objective prompts no longer stack; Day 1 auto guide trail.
- MusicDirector: upbeat tracks replaced with dark drones.
- E prompts made single-press (2026-11-25).

## 12. Known quirks
- Warning `rbxassetid://203785492 … Asset type does not match` is a Roblox-internal error, not game code. Harmless.
- DataStore saving only works in Studio if Game Settings → Security → "Enable Studio Access to API Services" is on. Otherwise progress is memory-only.
- `ServerStorage.Quarantine_Malware` holds a quarantined free-model script. It is inert; do not move it back.
- `ServerStorage.RemovedByClaude`: old removed scripts, kept for reference.
- Some minigames (e.g. WaterGauge) still have an in-minigame hold mechanic. That is separate from the E prompt.
- Save the place after changes (Ctrl+S / Publish).

## 13. Real-world grounding (for the paper/presentation)
Mechanics map to NASA's station emergency classes: fire (power isolation), depressurisation (O2 / valve tiers), toxic release (ammonia). Real incidents: Mir 1997 fire + collision, ISS 2013 false ammonia alarm. Isolation research: Mars-500 (520 days) and NASA HERA. The dreams model what isolation does to judgement. Full references are in the paper.
