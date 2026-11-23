#!/usr/bin/env python3
"""Wink Beat map generator: one song in, a draft map with easy, normal and hard charts out.

    pip install librosa
    python3 make_map.py song.mp3 --id 198 --title "198 км/ч" --audio winkbeat-198.m4a \
        --out ../../SpantherGaze/Resources/winkbeat-198.json

What it does:
1. Finds the tempo and the first beat: librosa's estimate, then a fine search of BPM and phase that lines the beat
   grid up with the onsets (an integer BPM wins when it is within 0.05, as DAW exports usually are).
2. Measures each bar's loudness and the onset strength on every half beat.
3. Per difficulty, picks the strongest half beats under the density and gap rules, turns long gaps into sliders,
   puts a spinner on quiet bars in the middle of the song, places objects along a flowing path whose hit zones
   never overlap, and assigns eyes.
4. Checks every chart with the same rules as WinkBeatMap.validate (GazeCore) and drops the weakest objects until
   it passes.
The map is a draft: play it, then tune it by hand in the JSON. Only music the team owns or CC0.
"""
import argparse, json, math, sys
import numpy as np

W, H = 844.0, 390.0            # reference field (pt), as WinkBeatField.reference
X_RANGE, Y_RANGE = (0.12, 0.88), (0.17, 0.83)

DIFF = {
    #          min gap, winks/s max, target/s, lead, zone, slider speed max (widths/s), spacing pt, half beats
    "easy":   dict(gap=1.0,  cap=0.85, target=0.62, lead=1.8,  zone=90, speed=0.45, spacing=235, halves=False, run=0),
    "normal": dict(gap=0.55, cap=1.3,  target=1.05, lead=1.35, zone=70, speed=0.6,  spacing=205, halves=True,  run=4),
    "hard":   dict(gap=0.4,  cap=2.0,  target=1.55, lead=1.05, zone=55, speed=0.8,  spacing=185, halves=True,  run=4),
}


def analyse(path, bpm=None, first=None):
    import librosa
    y, sr = librosa.load(path, sr=44100, mono=True)
    hop = 128
    fr = sr / hop
    dur = len(y) / sr
    env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop)

    def at(e, t):
        return np.interp(np.asarray(t) * fr, np.arange(len(e)), e)

    def grid_score(b, ph):
        return at(env, np.arange(ph, dur - 0.05, 60 / b)).mean()

    if bpm is None:
        est = float(np.atleast_1d(librosa.beat.beat_track(onset_envelope=env, sr=sr, hop_length=hop)[0])[0])
        while est > 140: est /= 2
        while est < 70: est *= 2
        best = max(((grid_score(b, ph), b, ph) for b in np.arange(est - 1.5, est + 1.5, 0.005)
                    for ph in np.arange(0, 60 / b, 0.004)))
        bpm = best[1]
        if abs(bpm - round(bpm)) < 0.05: bpm = float(round(bpm))
    T = 60 / bpm
    if first is None:
        first = max((grid_score(bpm, ph), ph) for ph in np.arange(0, T, 0.001))[1]
    # Downbeat: the beat phase (of 4) with the most low-end onset.
    S = np.abs(librosa.stft(y, n_fft=2048, hop_length=hop))
    freqs = librosa.fft_frequencies(sr=sr, n_fft=2048)
    kick = np.maximum(0, np.diff(np.log1p(S[(freqs >= 30) & (freqs < 150)].sum(0)), prepend=0))
    beats = np.arange(first, dur - 0.05, T)
    phase = int(np.argmax([at(kick, beats[k::4]).mean() for k in range(4)]))
    first_bar = first + phase * T
    rms = librosa.feature.rms(y=y, hop_length=hop)[0]
    rt = np.arange(len(rms)) / fr
    bars = []
    t = first_bar
    while t + 4 * T <= dur + 1e-6:
        m = (rt >= t) & (rt < t + 4 * T)
        bars.append(dict(t=t, rms=float(rms[m].mean())))
        t += 4 * T
    norm = np.percentile(env, 95) or 1
    return dict(bpm=float(bpm), T=T, first=float(first), first_bar=float(first_bar), dur=float(dur), bars=bars,
                strength=lambda ts: at(env, ts) / norm)


def wink_ok(times, cap):
    lo = 0
    for hi, t in enumerate(times):
        while t - times[lo] >= 5: lo += 1
        if hi - lo + 1 > cap * 5 + 1e-6: return False
    return True


def catmull(points, n=16):
    out = [points[0]]
    for i in range(len(points) - 1):
        p0, p1, p2, p3 = (np.array(points[max(0, i - 1)]), np.array(points[i]), np.array(points[i + 1]),
                          np.array(points[min(len(points) - 1, i + 2)]))
        for k in range(1, n + 1):
            t = k / n
            out.append(0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (3 * p1 - p0 - 3 * p2 + p3) * t ** 3))
    return out


def path_len(points):
    s = catmull(points)
    return sum(float(np.linalg.norm(s[i] - s[i - 1])) for i in range(1, len(s)))


def in_field(p):
    return X_RANGE[0] * W <= p[0] <= X_RANGE[1] * W and Y_RANGE[0] * H <= p[1] <= Y_RANGE[1] * H


def chart(a, name):
    d = DIFF[name]
    T, bars = a["T"], a["bars"]
    med = float(np.median([b["rms"] for b in bars]))
    loud = [b["rms"] >= 0.75 * med for b in bars]
    intro_end = next((i for i, l in enumerate(loud) if l), 0)
    quiet = [i for i, b in enumerate(bars) if i > intro_end + 2 and i < len(bars) - 2 and b["rms"] < 0.6 * med]
    spinners = [(bars[i]["t"], bars[i]["t"] + 4.5 * T) for i in quiet]
    start = bars[1]["t"] if len(bars) > 1 else a["first"]
    end_limit = min(a["dur"] - 1.0, bars[-1]["t"] + 3 * T)

    # Candidate times with weights: downbeats and beats first, then strong half beats.
    cands = []
    for bi, b in enumerate(bars):
        for h in range(8):
            t = b["t"] + h * T / 2
            if t < start or t > end_limit: continue
            if any(s0 - d["gap"] < t < s1 + d["gap"] for s0, s1 in spinners): continue
            if h % 2 == 1 and not d["halves"]: continue
            if name == "easy" and h % 4 != 0: continue
            w = float(a["strength"](t)) + (1.0 if h == 0 else 0.45 if h % 2 == 0 else 0.0)
            intro = bi < intro_end
            cands.append(dict(t=t, w=w, bar=bi, intro=intro))
    # Budget per 2 bars, halved in the intro.
    chosen = []
    for g in range(0, len(bars), 2):
        group = [c for c in cands if g <= c["bar"] < g + 2]
        if not group: continue
        budget = round(d["target"] * 8 * T * (0.5 if group[0]["intro"] else 1))
        for c in sorted(group, key=lambda c: -c["w"]):
            if budget <= 0: break
            if all(abs(c["t"] - o["t"]) >= d["gap"] for o in chosen):
                chosen.append(c); budget -= 1
    chosen.sort(key=lambda c: c["t"])
    while not wink_ok([c["t"] for c in chosen], d["cap"]):
        # Drop the weakest object in the densest window.
        times = [c["t"] for c in chosen]
        worst = max(range(len(times)), key=lambda i: sum(1 for t in times if abs(t - times[i]) < 2.5))
        window = [c for c in chosen if abs(c["t"] - times[worst]) < 2.5]
        chosen.remove(min(window, key=lambda c: c["w"]))

    objs = [dict(kind="circle", time=c["t"], bar=c["bar"]) for c in chosen]
    for s0, s1 in spinners:
        objs.append(dict(kind="spinner", time=s0, end=s1, bar=-1))
    objs.sort(key=lambda o: o["time"])
    # Hard is dense: make room for a slider every fourth bar by dropping the weaker object after a downbeat.
    if name == "hard":
        for i in range(len(objs) - 2, 0, -1):
            o, nxt = objs[i], objs[i + 1]
            if (o["kind"] == "circle" and nxt["kind"] == "circle" and o["bar"] >= intro_end and o["bar"] % 4 == 1
                    and abs((o["time"] - bars[o["bar"]]["t"])) < 1e-6 and i + 2 < len(objs)
                    and objs[i + 2]["time"] - d["gap"] - o["time"] >= 1.0 * T):
                objs.pop(i + 1)
    # Sliders: a long gap after a circle outside the intro becomes a slider, every second time.
    eligible = 0
    for i, o in enumerate(objs[:-1]):
        nxt = objs[i + 1]
        if o["kind"] != "circle" or o["bar"] < intro_end: continue
        room = nxt["time"] - d["gap"] - o["time"]
        if room >= 1.0 * T:
            eligible += 1
            if eligible % 2 == 1:
                beats = min(2.0, math.floor(room / (T / 2)) / 2)
                if beats >= 1.0:
                    o["kind"] = "slider"; o["end"] = o["time"] + beats * T

    # Positions along a flowing path; zones of objects on screen together never overlap.
    rng = np.random.default_rng(7)
    p = np.array([0.3 * W, 0.5 * H]); theta = 0.0; turn = 1
    placed = []
    for i, o in enumerate(objs):
        if o["kind"] == "spinner":
            o["pos"] = np.array([0.5 * W, 0.5 * H]); o["tail"] = o["pos"]; p = o["pos"]; continue
        if i % 6 == 0: turn = -turn
        prev_t = objs[i - 1]["time"] if i else o["time"] - T
        gap = o["time"] - prev_t
        dist = d["spacing"] * min(1.25, max(0.85, gap / (2 * T)))
        best = None
        for k, delta in enumerate([50, 80, 30, 110, 140, 170, 15, 200, 230, 260, 290, 320]):
            for dd in (dist, dist * 1.2, dist * 0.9, dist * 1.45):
                ang = theta + math.radians(turn * delta)
                q = p + dd * np.array([math.cos(ang), math.sin(ang)])
                if not in_field(q): continue
                ok = True
                for prev in placed:
                    if o["time"] - prev["endT"] >= d["lead"]: continue
                    if np.linalg.norm(q - prev["pos"]) < 2 * d["zone"] + 8 or np.linalg.norm(q - prev["tail"]) < 2 * d["zone"] + 8:
                        ok = False; break
                if ok: best = (q, ang); break
            if best: break
        if best is None:
            # Fall back to the free spot furthest from the recent objects.
            grid = [np.array([x * W, y * H]) for x in np.linspace(*X_RANGE, 9) for y in np.linspace(*Y_RANGE, 5)]
            recent = [pr for pr in placed if o["time"] - pr["endT"] < d["lead"]]
            q = max(grid, key=lambda g: min([np.linalg.norm(g - pr["pos"]) for pr in recent] +
                                            [np.linalg.norm(g - pr["tail"]) for pr in recent] + [1e9]))
            best = (q, math.atan2(q[1] - p[1], q[0] - p[0]))
        q, theta = best
        o["pos"] = q; o["tail"] = q
        if o["kind"] == "slider":
            dur_s = o["end"] - o["time"]
            length = min(0.85 * d["speed"] * W * dur_s, 260)
            o["repeats"] = 0
            if name == "hard" and dur_s >= 1.9 * T and length > 160:
                o["repeats"] = 1; length = min(length / 2, 200)
            pts = None
            for delta in [0, 40, -40, 80, -80, 120, -120, 160, -160, 200]:
                ang = theta + math.radians(turn * 30 + delta)
                dirv = np.array([math.cos(ang), math.sin(ang)]); perp = np.array([-dirv[1], dirv[0]])
                mid = q + dirv * length * 0.5 + perp * length * 0.22 * turn
                end = q + dirv * length
                if in_field(mid) and in_field(end):
                    pts = [mid, end]; break
            if pts is None:
                o["kind"] = "circle"; o.pop("end", None); o.pop("repeats", None)
            else:
                # Keep the orb under the speed limit.
                L = path_len([q] + pts) * (o["repeats"] + 1)
                if L / dur_s / W > d["speed"]:
                    k = d["speed"] * W * dur_s / L * 0.97
                    pts = [q + (pt - q) * k for pt in pts]
                o["path"] = pts
                o["tail"] = q if o["repeats"] % 2 == 1 else pts[-1]
                theta = math.atan2(pts[-1][1] - pts[-2][1] if len(pts) > 1 else pts[-1][1] - q[1],
                                   pts[-1][0] - q[0])
        p = o["tail"]
        placed.append(dict(pos=o["pos"], tail=o["tail"], endT=o.get("end", o["time"])))

    # Eyes.
    winks = [o for o in objs if o["kind"] != "spinner"]
    for i, o in enumerate(winks):
        if name == "easy":
            o["side"] = "any"
        elif name == "normal":
            phrase = o["bar"] // 4
            o["side"] = "any" if phrase % 2 == 0 else ("left" if o["bar"] % 2 == 0 else "right")
        else:
            phrase = o["bar"] // 4
            o["side"] = ("left" if (i // 2) % 2 == 0 else "right") if phrase % 2 == 0 else ("left" if i % 2 == 0 else "right")
    if d["run"]:
        run_side, run = None, 0
        for o in winks:
            if o["side"] != "any" and o["side"] == run_side:
                run += 1
                if run > d["run"]:
                    o["side"] = "right" if o["side"] == "left" else "left"; run_side, run = o["side"], 1
            else:
                run_side, run = o["side"], 1

    out = []
    for o in objs:
        e = dict(kind=o["kind"], time=round(o["time"], 3))
        if o["kind"] != "spinner":
            e["x"] = round(o["pos"][0] / W, 3); e["y"] = round(o["pos"][1] / H, 3); e["side"] = o["side"]
        if o["kind"] in ("slider", "spinner"):
            e["end"] = round(o["end"], 3)
        if o["kind"] == "slider":
            e["path"] = [[round(pt[0] / W, 3), round(pt[1] / H, 3)] for pt in o["path"]]
            if o["repeats"]: e["repeats"] = o["repeats"]
        out.append(e)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("audio_in")
    ap.add_argument("--id", required=True); ap.add_argument("--title", required=True)
    ap.add_argument("--author", default="SPANTHER team"); ap.add_argument("--license", default="Own track")
    ap.add_argument("--audio", required=True, help="file name in the app bundle")
    ap.add_argument("--bpm", type=float); ap.add_argument("--first", type=float)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    a = analyse(args.audio_in, args.bpm, args.first)
    print(f"bpm {a['bpm']:.3f}  first beat {a['first']:.3f} s  first bar {a['first_bar']:.3f} s  "
          f"{len(a['bars'])} bars  {a['dur']:.2f} s", file=sys.stderr)
    m = dict(format=1, id=args.id, title=args.title, author=args.author, license=args.license, audio=args.audio,
             bpm=round(a["bpm"], 3), firstBeatSec=round(a["first"], 3), durationSec=round(a["dur"], 3),
             charts={n: chart(a, n) for n in DIFF})
    for n, c in m["charts"].items():
        winks = sum(1 for o in c if o["kind"] != "spinner")
        print(f"{n}: {len(c)} objects, {winks} winks, "
              f"{sum(o['kind'] == 'slider' for o in c)} sliders, {sum(o['kind'] == 'spinner' for o in c)} spinners",
              file=sys.stderr)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(m, f, ensure_ascii=False, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main()
