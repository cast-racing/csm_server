#!/usr/bin/env python3
import socket, struct, io, os, signal, subprocess, time

RECV_PORT = 10000
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RECORD_SCRIPT = os.path.join(SCRIPT_DIR, "record_bag.sh")
MIN_CARS = 2
SESSION_TYPES = {0: "booking", 1: "practice", 2: "qualifying", 3: "race"}


def read_utf32(f):
    n = struct.unpack("<B", f.read(1))[0]
    return f.read(n * 4).decode("utf-32-le") if n else ""

def read_ascii(f):
    n = struct.unpack("<B", f.read(1))[0]
    return f.read(n).decode("ascii") if n else ""

def read_u8(f):
    return struct.unpack("<B", f.read(1))[0]

def read_u16(f):
    return struct.unpack("<H", f.read(2))[0]

def read_u32(f):
    return struct.unpack("<I", f.read(4))[0]

def read_float(f):
    return struct.unpack("<f", f.read(4))[0]

def fmt_lap(ms):
    return f"{ms // 60000}:{(ms % 60000) / 1000:06.3f}"


def parse_new_session(data):
    f = io.BytesIO(data)
    read_u8(f)              # proto_version
    read_u8(f)              # session_index
    read_u8(f)              # current_session_index
    read_u8(f)              # session_count
    read_utf32(f)           # server_name
    track = read_ascii(f)
    track_config = read_ascii(f)
    name = read_ascii(f)
    stype = read_u8(f)      # 0=booking, 1=practice, 2=qualifying, 3=race
    read_u16(f)             # time
    laps = read_u16(f)
    read_u16(f)             # wait_time
    ambient_temp = read_u8(f)
    track_temp = read_u8(f)
    weather = read_ascii(f)
    return {"track": track, "track_config": track_config, "session_type": stype,
            "name": name, "laps": laps, "ambient_temp": ambient_temp,
            "track_temp": track_temp, "weather": weather}

def parse_new_connection(data):
    f = io.BytesIO(data)
    driver = read_utf32(f)
    read_utf32(f)           # driver_guid
    car_id = read_u8(f)
    model = read_ascii(f)
    return {"car_id": car_id, "driver": driver, "model": model}

def parse_connection_closed(data):
    f = io.BytesIO(data)
    driver = read_utf32(f)
    read_utf32(f)           # driver_guid
    car_id = read_u8(f)
    return {"car_id": car_id, "driver": driver}

def parse_lap_completed(data):
    f = io.BytesIO(data)
    car_id = read_u8(f)
    lap_time = read_u32(f)  # ms
    cuts = read_u8(f)
    count = read_u8(f)      # leaderboard entry count
    leaderboard = []
    for _ in range(count):
        leaderboard.append({
            "car_id": read_u8(f),
            "best_time": read_u32(f),   # ms
            "laps": read_u16(f),
            "finished": read_u8(f) != 0,
        })
    grip = read_float(f)    # track grip 0.0-1.0
    return {"car_id": car_id, "lap_time": lap_time, "cuts": cuts,
            "leaderboard": leaderboard, "grip": grip}

def parse_chat(data):
    f = io.BytesIO(data)
    car_id = read_u8(f)
    message = read_utf32(f)
    return {"car_id": car_id, "message": message}

def parse_client_event(data):
    f = io.BytesIO(data)
    ev_type = read_u8(f)    # 10=car, 11=env
    car_id = read_u8(f)
    other_car_id = read_u8(f) if ev_type == 10 else 255
    impact_speed = read_float(f)
    wx = read_float(f)      # world x (meters)
    wy = read_float(f)      # world y (meters)
    wz = read_float(f)      # world z (meters)
    return {"car_id": car_id, "other_car_id": other_car_id,
            "impact_speed": impact_speed, "world_x": wx, "world_y": wy, "world_z": wz}


class Recorder:
    def __init__(self):
        self.session = None
        self.cars = {}
        self.proc = None
        self.session_dir = None
        self.session_name = None
        self.run_count = 0
        self.runs = []
        self.laps = {}
        self.collisions = []
        self.recorded_cars = {}
        self.start_time = None
        self.standings = []
        self.messages = []

    @property
    def recording(self):
        return self.proc is not None

    def on_new_session(self, info):
        if self.recording:
            self.stop()
        self.session = info
        self.cars.clear()
        self.session_dir = None
        self.session_name = None
        self.run_count = 0
        self.runs = []
        self.laps = {}
        self.collisions = []
        self.recorded_cars = {}
        self.standings = []
        self.messages = []
        track = info["track"].replace("ks_", "").replace("_", "-")
        stype = SESSION_TYPES.get(info["session_type"], "unknown")
        print(f"{track} {stype} {info['laps']} laps")

    def on_car_connected(self, info):
        self.cars[info["car_id"]] = info
        if self.recording:
            self.recorded_cars[info["car_id"]] = info
        print(f"  connected: {info['driver']} ({len(self.cars)} cars)")
        if not self.recording and len(self.cars) >= MIN_CARS:
            self.start()

    def on_car_disconnected(self, info):
        self.cars.pop(info["car_id"], None)
        print(f"  disconnected: {info['driver']} ({len(self.cars)} cars)")
        if self.recording and len(self.cars) < MIN_CARS:
            self.stop()

    def on_end_session(self):
        print("session ended")
        if self.recording:
            self.stop()
        self.session = None

    def on_lap_completed(self, info):
        cid = info["car_id"]
        print(f"  lap {cid}: {fmt_lap(info['lap_time'])}")
        if self.recording:
            self.laps.setdefault(cid, []).append(info)
            self.standings = info["leaderboard"]

    def on_collision(self, info):
        target = f"car_{info['other_car_id']}" if info["other_car_id"] != 255 else "wall"
        print(f"  collision: car_{info['car_id']} {target}")
        if self.recording:
            self.collisions.append(info)

    def on_chat(self, info):
        driver = self.cars.get(info["car_id"], {}).get("driver", f"car_{info['car_id']}")
        print(f"  chat {driver}: {info['message']}")
        if self.recording:
            self.messages.append({
                "time": time.time(),
                "car_id": info["car_id"],
                "message": info["message"],
            })

    def start(self):
        if not self.session:
            return
        track = self.session["track"].replace("ks_", "").replace("_", "-")
        stype = SESSION_TYPES.get(self.session["session_type"], "unknown")

        if not self.session_dir:
            self.session_name = f"{track}_{stype}_{time.strftime('%H-%M-%S')}"
            self.session_dir = os.path.expanduser(
                f"~/bags/iac/{time.strftime('%Y-%m-%d')}/{self.session_name}")

        run_name = f"{self.session_name}/run_{self.run_count}"
        self.start_time = time.time()
        self.recorded_cars.update(self.cars)

        self.proc = subprocess.Popen(
            [RECORD_SCRIPT, run_name], preexec_fn=os.setsid,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        os.makedirs(self.session_dir, exist_ok=True)
        self._write_session()
        print(f"recording run_{self.run_count}")

    def stop(self):
        if not self.proc:
            return
        duration = time.time() - self.start_time if self.start_time else 0
        run_idx = self.run_count
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGINT)
            self.proc.wait(timeout=10)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass
        self.proc = None
        self.runs.append({"idx": run_idx, "start": self.start_time, "duration": duration})
        self.run_count += 1
        self._write_session()
        print(f"saved run_{run_idx}")

    def _write_session(self):
        if not self.session_dir or not self.session:
            return
        path = os.path.join(self.session_dir, "session.txt")
        stype = SESSION_TYPES.get(self.session["session_type"], "unknown")
        with open(path, "w") as f:
            f.write(f"track: {self.session['track']}\n")
            config = self.session.get("track_config", "")
            if config:
                f.write(f"layout: {config}\n")
            f.write(f"session: {stype}\n")
            f.write(f"laps: {self.session['laps']}\n")
            f.write(f"date: {time.strftime('%Y-%m-%d')}\n")
            f.write(f"temp: {self.session['ambient_temp']}C air / {self.session['track_temp']}C track\n")
            weather = self.session.get("weather", "")
            if weather:
                f.write(f"weather: {weather}\n")

            if self.runs or self.recording:
                f.write(f"\nruns:\n")
                for run in self.runs:
                    m, s = divmod(int(run["duration"]), 60)
                    start_str = time.strftime('%H:%M:%S', time.localtime(run["start"]))
                    f.write(f"  run_{run['idx']}: {start_str} ({m}m {s}s)\n")
                if self.recording:
                    start_str = time.strftime('%H:%M:%S', time.localtime(self.start_time))
                    f.write(f"  run_{self.run_count}: {start_str} (recording)\n")

            f.write(f"\ncars:\n")
            for cid, car in self.recorded_cars.items():
                f.write(f"  car_{cid}: {car['driver']} ({car['model']})\n")

            if self.laps:
                f.write(f"\nlap_times:\n")
                best_time, best_car = None, None
                for cid, entries in self.laps.items():
                    parts = []
                    for e in entries:
                        t = fmt_lap(e["lap_time"])
                        if e["cuts"] > 0:
                            t += f" [{e['cuts']} cut{'s' if e['cuts'] > 1 else ''}]"
                        parts.append(t)
                    f.write(f"  car_{cid}: {', '.join(parts)}\n")
                    car_best = min(e["lap_time"] for e in entries)
                    if best_time is None or car_best < best_time:
                        best_time = car_best
                        best_car = cid
                if best_time is not None:
                    f.write(f"  best: {fmt_lap(best_time)} (car_{best_car})\n")

            if self.collisions:
                f.write(f"\ncollisions:\n")
                for c in self.collisions:
                    target = f"car_{c['other_car_id']}" if c["other_car_id"] != 255 else "wall"
                    f.write(f"  car_{c['car_id']} -> {target} @ {c['impact_speed']:.1f} km/h at ({c['world_x']:.0f}, {c['world_y']:.0f}, {c['world_z']:.0f})\n")

            if self.standings:
                f.write(f"\nstandings:\n")
                for i, entry in enumerate(self.standings):
                    line = f"  {i+1}. car_{entry['car_id']}  {fmt_lap(entry['best_time'])}  {entry['laps']} lap{'s' if entry['laps'] != 1 else ''}"
                    if entry["finished"]:
                        line += "  finished"
                    f.write(line + "\n")

            if self.messages:
                f.write(f"\nmessages:\n")
                for msg in self.messages:
                    ts = time.strftime('%H:%M:%S', time.localtime(msg["time"]))
                    driver = self.recorded_cars.get(msg["car_id"], {}).get("driver", f"car_{msg['car_id']}")
                    f.write(f"  [{ts}] {driver}: {msg['message']}\n")


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", RECV_PORT))
    sock.settimeout(1.0)

    rec = Recorder()
    print(f"UDP :{RECV_PORT} | min_cars={MIN_CARS}")

    try:
        while True:
            try:
                data, _ = sock.recvfrom(4096)
            except socket.timeout:
                if rec.recording and rec.proc and rec.proc.poll() is not None:
                    print(f"recorder crashed ({rec.proc.returncode}), restarting")
                    rec.proc = None
                    rec.run_count += 1
                    if len(rec.cars) >= MIN_CARS and rec.session:
                        rec.start()
                continue

            if not data:
                continue

            ptype = data[0]
            payload = data[1:]

            try:
                if ptype == 50:
                    rec.on_new_session(parse_new_session(payload))
                elif ptype == 51:
                    rec.on_car_connected(parse_new_connection(payload))
                elif ptype == 52:
                    rec.on_car_disconnected(parse_connection_closed(payload))
                elif ptype == 55:
                    rec.on_end_session()
                elif ptype == 73:
                    rec.on_lap_completed(parse_lap_completed(payload))
                elif ptype == 57:
                    rec.on_chat(parse_chat(payload))
                elif ptype == 130:
                    rec.on_collision(parse_client_event(payload))
            except Exception as e:
                print(f"parse error (type {ptype}): {e}")

    except KeyboardInterrupt:
        print()
        rec.stop()
    finally:
        sock.close()

if __name__ == "__main__":
    main()
