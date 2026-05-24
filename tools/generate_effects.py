from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BHAPTICS_DIR = ROOT / "reframework" / "data" / "bhaptics"
POSITIONS = ("VestFront", "VestBack", "ForearmL", "ForearmR")


VEST_LAYOUT = [{"index": i, "x": round((i % 4) / 3, 3), "y": round((i // 4) / 4, 3)} for i in range(20)]
ARM_LAYOUT = [{"index": i, "x": round(i / 2, 3), "y": 0.5} for i in range(3)]


def dot_mode(points):
    return {
        "dotMode": {
            "dotConnected": False,
            "feedback": [
                {
                    "startTime": 0,
                    "endTime": 1,
                    "playbackType": "NONE",
                    "pointList": [{"index": p[0], "intensity": p[1]} for p in points],
                }
            ],
        },
        "pathMode": {"feedback": []},
        "mode": "DOT_MODE",
    }


def empty_mode():
    return {
        "dotMode": {
            "dotConnected": False,
            "feedback": [
                {
                    "startTime": 0,
                    "endTime": 1,
                    "playbackType": "NONE",
                    "pointList": [],
                }
            ],
        },
        "pathMode": {"feedback": []},
        "mode": "DOT_MODE",
    }


def segment(name: str, start: int, duration: int, modes: dict[str, list[tuple[int, float]]]):
    resolved_modes = {}
    for position in POSITIONS:
        pts = modes.get(position, [])
        resolved_modes[position] = dot_mode(pts) if pts else empty_mode()
        for feedback in resolved_modes[position]["dotMode"]["feedback"]:
            feedback["endTime"] = duration

    return {
        "name": name,
        "startTime": start,
        "offsetTime": duration,
        "modes": resolved_modes,
    }


def tact_project(effect: dict) -> dict:
    project_duration_millis = max(
        (seg["start"] + seg["duration"] for seg in effect["segments"]),
        default=0,
    )
    return {
        "project": {
            "category": "RE9VR Simple Haptics",
            "tags": ["RE9VR", "bHaptics"],
            "mediaFileDuration": round(project_duration_millis / 1000, 3),
            "name": effect["key"],
            "id": effect["key"],
            "media": {"name": "", "mediaType": "None", "description": "", "link": "", "updateTime": 0, "duration": 0},
            "description": effect["description"],
            "tracks": [
                {
                    "enable": True,
                    "effects": [
                        segment(
                            f"Segment {idx + 1}",
                            seg["start"],
                            seg["duration"],
                            seg["modes"],
                        )
                        for idx, seg in enumerate(effect["segments"])
                    ],
                },
                {"enable": True, "effects": []},
            ],
            "layout": {
                "name": "RE9VR Simple Haptics",
                "type": "Tactot",
                "layouts": {
                    "VestFront": VEST_LAYOUT,
                    "VestBack": VEST_LAYOUT,
                    "ForearmL": ARM_LAYOUT,
                    "ForearmR": ARM_LAYOUT,
                },
            },
            "createdAt": 1779057600000,
            "updatedAt": 1779057600000,
        },
        "durationMillis": 0,
        "intervalMillis": 20,
        "size": 20,
    }


def seg(start: int, duration: int, **modes):
    return {"start": start, "duration": duration, "modes": modes}


def metadata_entry(effect: dict) -> dict:
    return {
        "key": effect["key"],
        "tact_file": effect["tact_file"],
        "description": effect["description"],
        "trigger_description": effect["trigger_description"],
        "preview_shortcut": effect["preview_shortcut"],
        "cooldown": effect["cooldown"],
    }


EFFECTS = [
    {
        "key": "RE9_SH_Startup",
        "tact_file": "RE9_SH_Startup.tact",
        "description": "Short confirmation pulse on the back and both sleeves.",
        "trigger_description": "game script starts and bHaptics bridge registers effects",
        "preview_shortcut": "0",
        "cooldown": 1.0,
        "segments": [
            seg(0, 120, VestBack=[(5, 0.55), (6, 0.55)], ForearmL=[(1, 0.45)], ForearmR=[(1, 0.45)]),
            seg(130, 90, VestFront=[(5, 0.45), (6, 0.45)]),
        ],
    },
    {
        "key": "RE9_SH_Pistol_Right",
        "tact_file": "RE9_SH_Pistol_Right.tact",
        "description": "Compact right-side handgun recoil on torso and right sleeve.",
        "trigger_description": "handgun or revolver shot",
        "preview_shortcut": "1",
        "cooldown": 0.055,
        "segments": [
            seg(0, 70, VestFront=[(3, 0.75), (7, 0.65)], VestBack=[(3, 0.45), (7, 0.45)], ForearmR=[(0, 0.95), (1, 0.80)]),
            seg(75, 80, VestFront=[(6, 0.45), (10, 0.35)], ForearmR=[(1, 0.45), (2, 0.35)]),
        ],
    },
    {
        "key": "RE9_SH_Auto_Right",
        "tact_file": "RE9_SH_Auto_Right.tact",
        "description": "Fast automatic-fire tick biased to the right arm.",
        "trigger_description": "SMG or automatic weapon fire",
        "preview_shortcut": "2",
        "cooldown": 0.035,
        "segments": [
            seg(0, 55, VestFront=[(3, 0.60), (7, 0.55)], ForearmR=[(0, 0.80), (1, 0.70)]),
            seg(60, 50, VestBack=[(7, 0.45), (11, 0.35)], ForearmR=[(1, 0.50)]),
        ],
    },
    {
        "key": "RE9_SH_Shotgun_Right",
        "tact_file": "RE9_SH_Shotgun_Right.tact",
        "description": "Heavy right shoulder blast with recoil aftershock.",
        "trigger_description": "shotgun or magnum shot",
        "preview_shortcut": "3",
        "cooldown": 0.12,
        "segments": [
            seg(0, 130, VestFront=[(2, 0.70), (3, 1.0), (6, 0.75), (7, 0.95)], VestBack=[(2, 0.55), (3, 0.85), (6, 0.60), (7, 0.80)], ForearmR=[(0, 1.0), (1, 1.0), (2, 0.85)]),
            seg(150, 110, VestBack=[(7, 0.75), (11, 0.55), (15, 0.40)], ForearmR=[(1, 0.65), (2, 0.45)]),
            seg(275, 65, VestFront=[(6, 0.35)], ForearmR=[(2, 0.30)]),
        ],
    },
    {
        "key": "RE9_SH_Rifle_Right",
        "tact_file": "RE9_SH_Rifle_Right.tact",
        "description": "Long-gun recoil through right shoulder and support sleeve.",
        "trigger_description": "rifle or launcher shot",
        "preview_shortcut": "4",
        "cooldown": 0.09,
        "segments": [
            seg(0, 100, VestFront=[(2, 0.65), (3, 0.75), (6, 0.65), (7, 0.70)], VestBack=[(2, 0.55), (3, 0.65), (6, 0.50), (7, 0.60)], ForearmR=[(0, 0.90), (1, 0.85)], ForearmL=[(0, 0.45)]),
            seg(120, 90, VestBack=[(6, 0.45), (10, 0.38)], ForearmR=[(1, 0.55), (2, 0.40)], ForearmL=[(1, 0.28)]),
        ],
    },
    {
        "key": "RE9_SH_Melee_Swing_R",
        "tact_file": "RE9_SH_Melee_Swing_R.tact",
        "description": "Right-arm melee swing sweep with light torso brush.",
        "trigger_description": "melee swing starts",
        "preview_shortcut": "5",
        "cooldown": 0.18,
        "segments": [
            seg(0, 80, ForearmR=[(0, 0.55)], VestFront=[(3, 0.28)]),
            seg(90, 80, ForearmR=[(1, 0.65)], VestFront=[(7, 0.32)]),
            seg(180, 80, ForearmR=[(2, 0.55)], VestFront=[(11, 0.28)]),
        ],
    },
    {
        "key": "RE9_SH_Melee_Hit_R",
        "tact_file": "RE9_SH_Melee_Hit_R.tact",
        "description": "Right-arm impact punch into the vest.",
        "trigger_description": "melee hit connects",
        "preview_shortcut": "6",
        "cooldown": 0.10,
        "segments": [
            seg(0, 95, ForearmR=[(1, 1.0), (2, 0.85)], VestFront=[(7, 0.80), (11, 0.75)], VestBack=[(7, 0.55), (11, 0.50)]),
            seg(120, 90, ForearmR=[(2, 0.45)], VestBack=[(10, 0.45), (11, 0.45)]),
        ],
    },
    {
        "key": "RE9_SH_Grenade",
        "tact_file": "RE9_SH_Grenade.tact",
        "description": "Left chest and sleeve pulse for throwable handling.",
        "trigger_description": "grenade, flash, or other throwable fire/use",
        "preview_shortcut": "7",
        "cooldown": 0.35,
        "segments": [
            seg(0, 120, VestFront=[(0, 0.80), (4, 0.70), (8, 0.55)], ForearmL=[(0, 0.85), (1, 0.60)]),
            seg(150, 120, VestBack=[(0, 0.55), (4, 0.45), (8, 0.35)], ForearmL=[(1, 0.70), (2, 0.50)]),
            seg(300, 80, VestFront=[(4, 0.45), (5, 0.35)], ForearmR=[(0, 0.35)]),
        ],
    },
    {
        "key": "RE9_SH_Holster_Hip",
        "tact_file": "RE9_SH_Holster_Hip.tact",
        "description": "Right hip draw/stow locator pulse.",
        "trigger_description": "weapon changes while the hip holster zone is active",
        "preview_shortcut": "8",
        "cooldown": 0.45,
        "segments": [
            seg(0, 95, VestFront=[(15, 0.65), (19, 0.75)], VestBack=[(15, 0.40), (19, 0.45)], ForearmR=[(2, 0.65)]),
            seg(115, 75, VestFront=[(11, 0.45), (15, 0.35)], ForearmR=[(1, 0.40)]),
        ],
    },
    {
        "key": "RE9_SH_Holster_Shoulder",
        "tact_file": "RE9_SH_Holster_Shoulder.tact",
        "description": "Right shoulder longarm draw/stow sweep.",
        "trigger_description": "longarm changes while the shoulder holster zone is active",
        "preview_shortcut": "9",
        "cooldown": 0.45,
        "segments": [
            seg(0, 100, VestBack=[(2, 0.65), (3, 0.85), (6, 0.55), (7, 0.70)], ForearmR=[(0, 0.55)]),
            seg(120, 95, VestFront=[(2, 0.45), (3, 0.50), (6, 0.35), (7, 0.40)], ForearmR=[(1, 0.45)]),
        ],
    },
    {
        "key": "RE9_SH_Holster_Chest",
        "tact_file": "RE9_SH_Holster_Chest.tact",
        "description": "Left chest slot draw/stow pulse.",
        "trigger_description": "weapon changes while the chest holster zone is active",
        "preview_shortcut": "a",
        "cooldown": 0.45,
        "segments": [
            seg(0, 95, VestFront=[(0, 0.70), (4, 0.60), (8, 0.45)], ForearmL=[(0, 0.55)]),
            seg(115, 85, VestBack=[(0, 0.45), (4, 0.35)], ForearmL=[(1, 0.40)]),
        ],
    },
    {
        "key": "RE9_SH_Heal",
        "tact_file": "RE9_SH_Heal.tact",
        "description": "Healing pulse spreading from left sleeve into the torso.",
        "trigger_description": "HP recovery or manual syringe heal succeeds",
        "preview_shortcut": "b",
        "cooldown": 1.0,
        "segments": [
            seg(0, 140, ForearmL=[(0, 0.85), (1, 0.70)], VestFront=[(8, 0.30)]),
            seg(180, 160, ForearmL=[(1, 0.70), (2, 0.55)], VestFront=[(8, 0.45), (9, 0.40)]),
            seg(380, 170, VestFront=[(5, 0.50), (6, 0.50), (9, 0.45), (10, 0.45)], VestBack=[(5, 0.35), (6, 0.35)]),
            seg(600, 170, VestFront=[(1, 0.35), (2, 0.35), (5, 0.30), (6, 0.30)], ForearmL=[(2, 0.30)]),
        ],
    },
    {
        "key": "RE9_SH_Player_Damage",
        "tact_file": "RE9_SH_Player_Damage.tact",
        "description": "Broad torso impact for player damage.",
        "trigger_description": "player damage calculation or HP loss",
        "preview_shortcut": "c",
        "cooldown": 0.42,
        "segments": [
            seg(0, 110, VestFront=[(5, 0.85), (6, 0.85), (9, 0.70), (10, 0.70)], VestBack=[(5, 0.55), (6, 0.55)], ForearmL=[(1, 0.35)], ForearmR=[(1, 0.35)]),
            seg(135, 120, VestBack=[(5, 0.70), (6, 0.70), (9, 0.55), (10, 0.55)], VestFront=[(9, 0.45), (10, 0.45)]),
            seg(285, 90, VestFront=[(13, 0.35), (14, 0.35)], VestBack=[(13, 0.30), (14, 0.30)]),
        ],
    },
    {
        "key": "RE9_SH_Electric_Damage",
        "tact_file": "RE9_SH_Electric_Damage.tact",
        "description": "Alternating torso and sleeve crackle for electric damage.",
        "trigger_description": "player damage with electric attack attribute",
        "preview_shortcut": "d",
        "cooldown": 0.9,
        "segments": [
            seg(0, 80, VestFront=[(1, 0.75), (6, 0.70), (11, 0.65)], ForearmL=[(0, 0.75), (2, 0.60)]),
            seg(105, 80, VestBack=[(2, 0.75), (5, 0.70), (10, 0.65)], ForearmR=[(0, 0.75), (2, 0.60)]),
            seg(220, 90, VestFront=[(3, 0.80), (8, 0.65), (13, 0.55)], ForearmL=[(1, 0.80)], ForearmR=[(1, 0.80)]),
            seg(360, 100, VestBack=[(0, 0.65), (7, 0.70), (14, 0.55)], ForearmL=[(2, 0.55)], ForearmR=[(0, 0.55)]),
            seg(540, 110, VestFront=[(5, 0.50), (6, 0.50), (9, 0.45), (10, 0.45)], ForearmL=[(1, 0.40)], ForearmR=[(1, 0.40)]),
        ],
    },
    {
        "key": "RE9_SH_Player_Death",
        "tact_file": "RE9_SH_Player_Death.tact",
        "description": "Long fading collapse pulse for player death.",
        "trigger_description": "player death",
        "preview_shortcut": "e",
        "cooldown": 4.0,
        "segments": [
            seg(0, 180, VestFront=[(4, 0.85), (5, 0.90), (6, 0.90), (7, 0.85)], VestBack=[(4, 0.65), (5, 0.70), (6, 0.70), (7, 0.65)], ForearmL=[(1, 0.50)], ForearmR=[(1, 0.50)]),
            seg(260, 220, VestFront=[(8, 0.65), (9, 0.70), (10, 0.70), (11, 0.65)], VestBack=[(8, 0.50), (9, 0.55), (10, 0.55), (11, 0.50)]),
            seg(580, 250, VestFront=[(12, 0.45), (13, 0.50), (14, 0.50), (15, 0.45)], VestBack=[(12, 0.35), (13, 0.40), (14, 0.40), (15, 0.35)]),
            seg(930, 200, VestFront=[(17, 0.25), (18, 0.25)], VestBack=[(17, 0.22), (18, 0.22)]),
        ],
    },
    {
        "key": "RE9_SH_Camera_Shake",
        "tact_file": "RE9_SH_Camera_Shake.tact",
        "description": "Short environmental shock on the torso.",
        "trigger_description": "camera shake request",
        "preview_shortcut": "f",
        "cooldown": 0.55,
        "segments": [
            seg(0, 80, VestFront=[(5, 0.55), (6, 0.55), (9, 0.50), (10, 0.50)], VestBack=[(5, 0.45), (6, 0.45), (9, 0.40), (10, 0.40)]),
            seg(100, 90, VestBack=[(9, 0.50), (10, 0.50), (13, 0.40), (14, 0.40)]),
        ],
    },
    {
        "key": "RE9_SH_Add_Item",
        "tact_file": "RE9_SH_Add_Item.tact",
        "description": "Small chest and sleeve pickup confirmation.",
        "trigger_description": "inventory add item",
        "preview_shortcut": "g",
        "cooldown": 0.25,
        "segments": [
            seg(0, 75, VestFront=[(4, 0.50), (8, 0.45)], ForearmL=[(0, 0.45)]),
            seg(90, 60, VestFront=[(5, 0.35)], ForearmL=[(1, 0.32)]),
        ],
    },
    {
        "key": "RE9_SH_Reload_Mag_Grab",
        "tact_file": "RE9_SH_Reload_Mag_Grab.tact",
        "description": "Left sleeve and pouch tap for grabbing reload ammo.",
        "trigger_description": "manual reload mag, shell, or bullet grab",
        "preview_shortcut": "h",
        "cooldown": 0.12,
        "segments": [
            seg(0, 70, ForearmL=[(0, 0.70), (1, 0.55)], VestFront=[(12, 0.35), (16, 0.30)]),
            seg(85, 60, ForearmL=[(1, 0.45), (2, 0.35)]),
        ],
    },
    {
        "key": "RE9_SH_Reload_Mag_Insert",
        "tact_file": "RE9_SH_Reload_Mag_Insert.tact",
        "description": "Firm support-hand insert click into the weapon.",
        "trigger_description": "manual reload mag, shell, or bullet insert",
        "preview_shortcut": "i",
        "cooldown": 0.16,
        "segments": [
            seg(0, 80, ForearmL=[(1, 0.80), (2, 0.65)], VestFront=[(6, 0.45), (10, 0.45)]),
            seg(100, 70, ForearmL=[(2, 0.50)], VestBack=[(6, 0.35), (10, 0.30)]),
        ],
    },
    {
        "key": "RE9_SH_Reload_Mag_Drop",
        "tact_file": "RE9_SH_Reload_Mag_Drop.tact",
        "description": "Low release pulse for magazine or shell drop.",
        "trigger_description": "manual reload magazine or shell drop",
        "preview_shortcut": "j",
        "cooldown": 0.18,
        "segments": [
            seg(0, 65, ForearmL=[(2, 0.42)], VestFront=[(15, 0.45), (19, 0.45)]),
            seg(80, 55, VestBack=[(15, 0.30), (19, 0.30)]),
        ],
    },
    {
        "key": "RE9_SH_Reload_Rack_Back",
        "tact_file": "RE9_SH_Reload_Rack_Back.tact",
        "description": "Support sleeve pull-back for slide, bolt, or pump action.",
        "trigger_description": "manual rack or pump pulled back",
        "preview_shortcut": "k",
        "cooldown": 0.14,
        "segments": [
            seg(0, 65, ForearmL=[(2, 0.80)], VestFront=[(6, 0.35)]),
            seg(70, 65, ForearmL=[(1, 0.75)], VestBack=[(6, 0.40)]),
            seg(140, 45, ForearmL=[(0, 0.55)], VestBack=[(2, 0.32)]),
        ],
    },
    {
        "key": "RE9_SH_Reload_Rack_Forward",
        "tact_file": "RE9_SH_Reload_Rack_Forward.tact",
        "description": "Support sleeve forward lock for slide, bolt, or pump action.",
        "trigger_description": "manual rack or pump closes",
        "preview_shortcut": "l",
        "cooldown": 0.14,
        "segments": [
            seg(0, 55, ForearmL=[(0, 0.65)], VestBack=[(2, 0.32)]),
            seg(60, 55, ForearmL=[(1, 0.75)], VestFront=[(6, 0.38)]),
            seg(120, 50, ForearmL=[(2, 0.85)], VestFront=[(10, 0.45)]),
        ],
    },
    {
        "key": "RE9_SH_Dry_Fire_Right",
        "tact_file": "RE9_SH_Dry_Fire_Right.tact",
        "description": "Tiny right sleeve trigger click for dry fire.",
        "trigger_description": "dry trigger pull",
        "preview_shortcut": "m",
        "cooldown": 0.12,
        "segments": [
            seg(0, 55, ForearmR=[(0, 0.55), (1, 0.35)]),
        ],
    },
    {
        "key": "RE9_SH_Barrel_Close",
        "tact_file": "RE9_SH_Barrel_Close.tact",
        "description": "Short cylinder or barrel latch click.",
        "trigger_description": "revolver cylinder or break action closes",
        "preview_shortcut": "n",
        "cooldown": 0.18,
        "segments": [
            seg(0, 70, ForearmR=[(1, 0.65)], VestFront=[(6, 0.40)]),
            seg(90, 60, ForearmR=[(2, 0.42)], VestBack=[(6, 0.25)]),
        ],
    },
    {
        "key": "RE9_SH_Throwable_Equip",
        "tact_file": "RE9_SH_Throwable_Equip.tact",
        "description": "Chest slot and sleeve pulse when a throwable is equipped.",
        "trigger_description": "throwable long-press equip",
        "preview_shortcut": "o",
        "cooldown": 0.35,
        "segments": [
            seg(0, 90, VestFront=[(0, 0.55), (4, 0.50)], ForearmL=[(0, 0.45)]),
            seg(110, 80, ForearmR=[(0, 0.45)], VestFront=[(5, 0.35)]),
        ],
    },
    {
        "key": "RE9_SH_Throwable_Release",
        "tact_file": "RE9_SH_Throwable_Release.tact",
        "description": "Throwing-arm sweep and torso release for a thrown item.",
        "trigger_description": "throwable release succeeds",
        "preview_shortcut": "p",
        "cooldown": 0.35,
        "segments": [
            seg(0, 75, ForearmR=[(0, 0.75)], VestFront=[(7, 0.38)]),
            seg(90, 80, ForearmR=[(1, 0.80)], VestFront=[(6, 0.45), (10, 0.35)]),
            seg(190, 75, ForearmR=[(2, 0.65)], VestBack=[(6, 0.35), (10, 0.30)]),
        ],
    },
    {
        "key": "RE9_SH_Block_Stance",
        "tact_file": "RE9_SH_Block_Stance.tact",
        "description": "Subtle left forearm brace cue for block stance.",
        "trigger_description": "manual block/parry pose becomes active",
        "preview_shortcut": "y",
        "cooldown": 0.65,
        "segments": [
            seg(0, 80, ForearmL=[(0, 0.60), (1, 0.50)], VestFront=[(4, 0.28)]),
            seg(105, 70, ForearmL=[(1, 0.45), (2, 0.35)]),
        ],
    },
    {
        "key": "RE9_SH_Block_Impact",
        "tact_file": "RE9_SH_Block_Impact.tact",
        "description": "Forearm and front torso impact while blocking.",
        "trigger_description": "incoming hit while block pose is active",
        "preview_shortcut": "r",
        "cooldown": 0.28,
        "segments": [
            seg(0, 95, ForearmL=[(1, 1.0), (2, 0.80)], VestFront=[(4, 0.80), (5, 0.70), (8, 0.60), (9, 0.55)]),
            seg(120, 90, ForearmL=[(2, 0.55)], VestBack=[(4, 0.45), (8, 0.35)]),
        ],
    },
    {
        "key": "RE9_SH_Parry_Success",
        "tact_file": "RE9_SH_Parry_Success.tact",
        "description": "Sharp successful parry snap across forearm and vest.",
        "trigger_description": "native parry success event",
        "preview_shortcut": "s",
        "cooldown": 0.35,
        "segments": [
            seg(0, 80, ForearmL=[(1, 1.0), (2, 0.90)], VestFront=[(4, 0.80), (8, 0.70)]),
            seg(100, 90, ForearmR=[(0, 0.55)], VestBack=[(4, 0.55), (8, 0.45)]),
            seg(220, 80, VestFront=[(5, 0.45), (9, 0.35)], ForearmL=[(2, 0.40)]),
        ],
    },
    {
        "key": "RE9_SH_Syringe_Ready",
        "tact_file": "RE9_SH_Syringe_Ready.tact",
        "description": "Right sleeve confirmation when the manual syringe is armed.",
        "trigger_description": "optional external event: manual syringe spawns",
        "preview_shortcut": "t",
        "cooldown": 0.4,
        "segments": [
            seg(0, 70, ForearmR=[(0, 0.55), (1, 0.45)], VestFront=[(8, 0.25)]),
            seg(90, 50, ForearmR=[(1, 0.35)]),
        ],
    },
    {
        "key": "RE9_SH_Syringe_Zone",
        "tact_file": "RE9_SH_Syringe_Zone.tact",
        "description": "Small right sleeve alignment cue for syringe injection zone.",
        "trigger_description": "optional external event: manual syringe enters valid injection zone",
        "preview_shortcut": "u",
        "cooldown": 0.2,
        "segments": [
            seg(0, 55, ForearmR=[(1, 0.50)], VestFront=[(8, 0.20)]),
            seg(65, 45, ForearmR=[(2, 0.35)]),
        ],
    },
    {
        "key": "RE9_SH_Syringe_Fail",
        "tact_file": "RE9_SH_Syringe_Fail.tact",
        "description": "Low right sleeve buzz for failed manual syringe use.",
        "trigger_description": "optional external event: manual syringe use fails or no stock is available",
        "preview_shortcut": "v",
        "cooldown": 0.35,
        "segments": [
            seg(0, 90, ForearmR=[(0, 0.45), (1, 0.45)]),
            seg(120, 90, ForearmR=[(1, 0.38), (2, 0.38)]),
        ],
    },
    {
        "key": "RE9_SH_Bike_Start",
        "tact_file": "RE9_SH_Bike_Start.tact",
        "description": "Low torso and sleeve pulse when bike mode starts.",
        "trigger_description": "bike first-person mode becomes active",
        "preview_shortcut": "w",
        "cooldown": 1.0,
        "segments": [
            seg(0, 100, VestFront=[(12, 0.45), (13, 0.50), (14, 0.50), (15, 0.45)], ForearmL=[(1, 0.35)], ForearmR=[(1, 0.35)]),
            seg(130, 80, VestBack=[(12, 0.35), (13, 0.40), (14, 0.40), (15, 0.35)]),
        ],
    },
    {
        "key": "RE9_SH_Bike_Rumble",
        "tact_file": "RE9_SH_Bike_Rumble.tact",
        "description": "Short low torso engine rumble tick while bike mode is active.",
        "trigger_description": "periodic bike mode rumble",
        "preview_shortcut": "x",
        "cooldown": 0.55,
        "segments": [
            seg(0, 70, VestFront=[(13, 0.35), (14, 0.35)], VestBack=[(13, 0.30), (14, 0.30)]),
            seg(90, 60, VestFront=[(17, 0.28), (18, 0.28)], VestBack=[(17, 0.24), (18, 0.24)]),
        ],
    },
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate RE9VR Simple Haptics metadata and optionally regenerate .tact files."
    )
    parser.add_argument(
        "--write-tact",
        action="store_true",
        help="Overwrite all .tact files from the Python effect definitions.",
    )
    parser.add_argument(
        "--no-write-missing-tact",
        action="store_true",
        help="Do not create generated .tact files for effects whose .tact file is missing.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    BHAPTICS_DIR.mkdir(parents=True, exist_ok=True)
    metadata = []
    written_tact = 0
    preserved_tact = 0
    for effect in EFFECTS:
        tact_path = BHAPTICS_DIR / effect["tact_file"]
        tact_exists = tact_path.exists()
        should_write_tact = args.write_tact or (not tact_exists and not args.no_write_missing_tact)
        if should_write_tact:
            tact_data = tact_project(effect)
            tact_path.write_text(
                json.dumps(tact_data, separators=(",", ":"), ensure_ascii=False),
                encoding="utf-8",
            )
            written_tact += 1
        elif tact_exists:
            preserved_tact += 1

        metadata.append(metadata_entry(effect))

    (BHAPTICS_DIR / "re9vr_simple_haptics_effects.json").write_text(
        json.dumps({"effects": metadata}, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        "Wrote re9vr_simple_haptics_effects.json; "
        f"preserved {preserved_tact} .tact files, wrote {written_tact} .tact files."
    )


if __name__ == "__main__":
    main()
