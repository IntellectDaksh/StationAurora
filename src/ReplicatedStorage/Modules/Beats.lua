--!strict
-- Story beats: companion dialogue + tutorial hint cards, fired by the director or by
-- objectives (ObjectiveDef.beatOnActivate / beatOnComplete). Sent to the client as
-- PlayCue("Dialogue", { id, lines, hint }). Blocking beats hold the director for the
-- sum of line holds. %s in text = operator name.
--
-- Director hook ids (missing id = skipped silently):
--   Reality_Wake, Reality_Tasks, Reality_Distress, Reality_NoReply
--   Dream<N>_Wake, Dream<N>_Start, Dream<N>_Clean   (N = 1..4)
--   Choice

export type Line = { speaker: string, text: string, hold: number }
export type Hint = { text: string, keys: { string }? } -- keys e.g. {"W","A","S","D"} or {"F"}
export type Beat = { lines: { Line }?, hint: Hint? }

-- Also referenced by objectives (beatOnActivate / beatOnComplete): Gen_Find, Gen_Online, Torch_On.
-- AURA voice: calm, dry, a little too cheerful in reality; in dreams it slips (wrong day,
-- a crew member who isn't aboard, dropped signal). Lines <= 90 chars, hold 2.5-4s.

local function A(text: string, hold: number?): Line
	return { speaker = "AURA", text = text, hold = hold or 3.2 }
end

local Beats: { [string]: Beat } = {
	-- Day structure (GameStateManager.phaseDay / phaseSleep): Day<N>_Intro at wake, Day<N>_Sleep at bedtime
	Day1_Intro = { lines = { A("Standby cycle interrupted, %s. Main power is down.", 3.4), A("Five crew off-station. It's just us. Torch first.", 3.2) } },
	Day2_Intro = {
		lines = {
			A("Mission day 213. Still no reply to the distress call.", 3.4),
			A("Last night's faults are still in the log. So is that contact. No transponder.", 3.8),
			A("Get a clean lock from the observatory. Then hail it.", 3),
		},
	},
	Day3_Intro = {
		lines = {
			A("Day three. The ship you locked yesterday is still off the west window.", 3.8),
			A("It hasn't moved. It hasn't answered. Neither has the crew.", 3.4),
			A("You were talking in your sleep, %s. Something about breakers.", 3.4),
		},
	},
	Day4_Intro = {
		lines = {
			A("Mission day 214. Or 215. My clock and yours disagree.", 3.2),
			A("The grid damage from last night is real enough. I'm routing around it.", 3.4),
			A("The ship is transmitting on the crew channel. Our crew channel.", 3.6),
			A("Finish the checklist. Then answer it.", 3),
		},
	},
	Day_Sleep = { lines = { A("That's the day done, %s. Pod's warm. Sleep.", 3.2) } },
	Sleep_NotYet = { lines = {}, hint = { text = "Finish today's tasks first" } },
	Scope_Lock = {
		lines = {
			A("Lock confirmed. Hull, running lights, no markings.", 3.4),
			A("That's real, %s. Not a sensor ghost. I'm logging it with your name on it.", 3.8),
		},
	},
	Hail_NoAnswer = { lines = { A("Hail sent on every band. It heard us. It isn't answering.", 3.4) } },
	Comms_Voice = { lines = { A("That was a voice. Okafor's voice. Okafor isn't aboard.", 3.6) } },
	Ship_Answer = { lines = { A("Transmitted. It's turning toward us, %s.", 3.2) } },

	Reality_Sleep = { lines = { { speaker = "AURA", text = "Checklist complete. Your pod is warm, %s. Get some sleep.", hold = 3.5 } } },
	O2_Low = { lines = { { speaker = "AURA", text = "Your suit oxygen is low. Nearest O2 station is marked.", hold = 3.5 } } },
	-- Reality -------------------------------------------------------------
	Reality_Wake = {
		lines = {
			A("Good morning, %s. Mission day 212. Main power is down, which is new.", 3.6),
			A("Your torch is on your belt. I'd use it.", 3),
		},
		hint = { text = "Press F for your torch", keys = { "F" } },
	},
	Torch_On = {
		lines = { A("Better. Follow the glowing markers, I'll keep them lit.", 2.8) },
	},
	Gen_Find = {
		lines = {
			A("Backup generator's on this deck, east side, past your quarters. Follow the markers.", 3.6),
			A("Panel's on the wall. You can't miss it. Well -- you could. Don't.", 3.2),
		},
	},
	Gen_Online = {
		lines = {
			A("There we go. Lights, air, coffee. In order of importance.", 3.2),
			A("Checklist's on your board next. Watch your oxygen, and top up at any O2 station.", 3.6),
		},
	},
	Reality_Tasks = {
		lines = {
			A("Morning checklist is on your board, %s. Same as yesterday.", 3.4),
			A("And the day before. I find routine very calming.", 3),
		},
	},
	Reality_Distress = {
		lines = {
			A("The crew shuttle missed its check-in. Eleven hours now.", 3.4),
			A("Comms is warm. Try them. I'm sure it's paperwork.", 3.2),
		},
	},
	Reality_NoReply = {
		lines = {
			A("Nothing. I'll keep the channel open.", 3),
			A("You should rest, %s. You look like you haven't slept in days.", 3.6),
		},
	},

	-- Dream 1: System Anomaly ----------------------------------------------
	Dream1_Wake = {
		lines = { A("%s. Wake up. It's 02:14.", 2.8), A("Something tripped the proximity alarm.", 2.8) },
	},
	Dream1_Start = {
		lines = {
			A("Unlisted contact on the scanner. Probably ice. Check the windows and radar.", 3.8),
		},
	},
	Dream1_Clean = {
		lines = { A("No anomaly found. I logged it anyway. I log everything.", 3.4) },
	},

	-- Dream 2: The Foreign Ship --------------------------------------------
	Dream2_Wake = {
		lines = { A("%s? Main lights just dropped. Stay where I can hear you.", 3.2) },
	},
	Dream2_Start = {
		lines = {
			A("Lights are out. There is a vessel off the west windows.", 3.2),
			A("It has no name. It has no--", 2.4),
			A("...", 2.2),
			A("Observatory scope. Please. I can't [SIGNAL LOST]", 3.2),
		},
	},
	Dream2_Clean = {
		lines = { A("Lock logged. It's still out there. I think.", 3.2) },
	},

	-- Dream 3: Power Down --------------------------------------------------
	Dream3_Wake = {
		lines = { A("Wake up, Okafor.", 2.6), A("Sorry. Good morning, %s. Okafor isn't aboard.", 3.2) },
	},
	Dream3_Start = {
		lines = {
			A("Main bus is offline. The grid wants three breakers, in order.", 3.4),
			A("Keep the torch up. I can't see you in the dark. [SIGNAL LOST]", 3.6),
		},
	},
	Dream3_Clean = {
		lines = {
			A("Power restored. Nobody else is on this deck. I checked twice.", 3.4),
			A("Go back to your pod, %s. Please.", 3),
			A("That knocking is the hull cooling. It's nothing. Don't go and look.", 3.6),
		},
	},

	-- Dream 4: Cascading Failure -------------------------------------------
	Dream4_Wake = {
		lines = { A("%s. Mission day 2-2-2-2--", 3) },
	},
	Dream4_Start = {
		lines = {
			A("Oxygen critical. Life support, now. Don't run, you'll use more air.", 3.6),
			A("Okafor and Reyes are fine. They're asleep in the pods. [SIGNAL LOST]", 3.8),
		},
	},
	Dream4_Clean = {
		lines = { A("O2 flow restored. See? Everything is exactly where you left it.", 3.4) },
	},

	-- Story choices (v4) ----------------------------------------------------
	Knock_Comply = { lines = { A("Thank you. Stay in the pod. The knocking stops if you don't listen.", 3.6) } },
	Knock_Found = {
		lines = {
			A("There's nothing behind that panel, %s. There never was.", 3.4),
			A("Three knocks. Then three more. Like someone counting days.", 3.6),
		},
	},
	Day4_Knocked = { lines = { A("You didn't go back to the pod last night. I noticed. So did something else.", 3.8) } },
	Day4_Complied = { lines = { A("You listened last night. Thank you. The knocking stopped at 03:10.", 3.6) } },
	Day4_Dish = { lines = { A("The dish you fixed is holding a carrier. Someone out there knows we're here.", 3.8) } },
	Dish_Fixed = { lines = { A("Dish aligned. I'm hearing a carrier, %s. Faint. Real.", 3.4) } },
	Duck_Found = { lines = { A("Is that a rubber duck? Lindqvist lost one on day 212. This day 212, I mean.", 3.8) } },
	Ship_Silent = { lines = { A("Comms breaker pulled. We're dark. It can't hear us now. I hope.", 3.4) } },
	Day214_Intercom = {
		lines = {
			{ speaker = "INTERCOM", text = "...happy mission day two-twelve, everybody...", hold = 3 },
			{ speaker = "OKAFOR", text = "Who's on galley duty? %s, you're on galley duty.", hold = 3.2 },
			A("That's a recording. From mission day 212. I don't know which one.", 3.6),
		},
	},
	Dream4_Silent = { lines = { A("The comms breaker is still pulled. The crew channel is still talking.", 3.6) } },
	Dream4_Answered = { lines = { A("It answered your transmission. It keeps saying your name.", 3.4) } },

	-- Task chain (beatOnComplete): each finished job says why it mattered and where to go next.
	T_LS_Done = { lines = { A("Scrubbers cycling. Air's clean for now. File the status report so Ground sees it.", 3.6) } },
	T_Log_Done = { lines = { A("Report filed. It sat in the outbox. Same as yesterday's. Check the task board.", 3.6) } },
	T_Board_Done = { lines = { A("One line on the board isn't mine. Water recycler, washroom. Okafor's handwriting.", 3.8) } },
	T_Recycler_Done = { lines = { A("Recycler's running. That's every system green. Now we can call for help.", 3.4) } },
	T_Pipe2_Done = { lines = { A("Coolant's flowing. The contact hasn't moved since you locked it. Hail it.", 3.4) } },
	T_Cal3_Done = { lines = { A("Hull sensors read a mass off the west side. Close. Closer than yesterday.", 3.6) } },
	T_Pipe4_Done = { lines = { A("O2 lines rerouted. Same valve Reyes fixed three times. It keeps failing the same way.", 3.8) } },
	T_Cal4_Done = { lines = { A("Water's clean. Tank shows six people's worth of usage. There's one of you.", 3.6) } },
	T_Board4_Done = { lines = { A("Last item on the board: the ship. Answer it from comms, or pull the breaker.", 3.6) } },

	-- Choice ---------------------------------------------------------------
	Choice = {
		lines = {
			A("I can't tell which of these is the dream, %s.", 3.2),
			A("You'll have to decide. I'll log whatever you choose.", 3.4),
		},
	},
}

return Beats
