#!/usr/bin/env python3
"""Watch /state/odom and resend the FROM PIT trajectory after a teleport."""

from __future__ import annotations

import math
import subprocess
import time
from typing import Optional, Tuple

import rclpy
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import QoSProfile

TOPIC = "/state/odom"
DISTANCE_THRESHOLD_M = 5.0
MAX_JUMP_DT_S = 0.1
COMMAND_COOLDOWN_S = 10.0
POST_COMMAND_IGNORE_S = 2.0
PLANNING_TMUX_PANE = "iac_ros2:0.4"
PLANNING_TMUX_COMMAND = "ros2 launch robot_bringup planning.launch.py"
PLANNING_RESTART_DELAY_S = 1.0
PLANNING_STARTUP_DELAY_S = 2.0
TRAJECTORY_COMMAND = ["ros2", "run", "trajectory_generator", "set_trajectory_node"]
TRAJECTORY_SELECTION = "4"
MANEUVER_SELECTION = "5"
QOS_DEPTH = 1


class MpcRespawnMonitor(Node):
    def __init__(self) -> None:
        super().__init__("mpc_respawn_monitor")

        self._last_position: Optional[Tuple[float, float, float]] = None
        self._last_stamp_s: Optional[float] = None
        self._last_command_time = 0.0
        self._ignore_jumps_until = 0.0

        self._subscription = self.create_subscription(
            Odometry,
            TOPIC,
            self._odom_callback,
            QoSProfile(depth=QOS_DEPTH),
        )

        self.get_logger().info(
            f"Watching {TOPIC} for jumps > {DISTANCE_THRESHOLD_M:.2f} m "
            f"within {MAX_JUMP_DT_S:.3f} s"
        )

    def _odom_callback(self, msg: Odometry) -> None:
        pos = msg.pose.pose.position
        current = (float(pos.x), float(pos.y), float(pos.z))
        stamp_s = float(msg.header.stamp.sec) + float(msg.header.stamp.nanosec) * 1e-9
        now = self.get_clock().now().nanoseconds * 1e-9

        if self._last_position is None or self._last_stamp_s is None:
            self._last_position = current
            self._last_stamp_s = stamp_s
            return

        distance = math.dist(current, self._last_position)
        dt = stamp_s - self._last_stamp_s
        self._last_position = current
        self._last_stamp_s = stamp_s

        if now < self._ignore_jumps_until:
            return

        if dt <= 0.0 or dt > MAX_JUMP_DT_S:
            return
        if distance <= DISTANCE_THRESHOLD_M:
            return

        if now - self._last_command_time < COMMAND_COOLDOWN_S:
            self.get_logger().warn(
                f"Detected {distance:.2f} m jump but command is still in cooldown."
            )
            return

        self.get_logger().warn(
            f"Detected {distance:.2f} m jump on {TOPIC} in {dt:.3f} s; "
            "sending FROM PIT trajectory command."
        )
        self._run_trajectory_command()
        self._last_command_time = now
        self._ignore_jumps_until = now + POST_COMMAND_IGNORE_S
        self._last_position = None
        self._last_stamp_s = None

    def _run_trajectory_command(self) -> None:
        command_input = f"{TRAJECTORY_SELECTION}\n{MANEUVER_SELECTION}\n"

        try:
            self._restart_planning_stack()
            completed = subprocess.run(
                TRAJECTORY_COMMAND,
                input=command_input,
                capture_output=True,
                check=True,
                text=True,
            )
            if completed.stdout.strip():
                self.get_logger().info(
                    f"Trajectory command stdout: {completed.stdout.strip()}"
                )
            if completed.stderr.strip():
                self.get_logger().warn(
                    f"Trajectory command stderr: {completed.stderr.strip()}"
                )
        except subprocess.CalledProcessError as exc:
            self.get_logger().error(
                f"Trajectory command failed with code {exc.returncode}"
            )
            if exc.stdout.strip():
                self.get_logger().error(f"command stdout: {exc.stdout.strip()}")
            if exc.stderr.strip():
                self.get_logger().error(f"command stderr: {exc.stderr.strip()}")
        except Exception as exc:
            self.get_logger().error(f"Failed to run trajectory command: {exc}")

    def _restart_planning_stack(self) -> None:
        self.get_logger().info("Restarting planning stack before sending trajectory command.")

        try:
            subprocess.run(
                ["tmux", "send-keys", "-t", PLANNING_TMUX_PANE, "C-c"],
                capture_output=True,
                check=True,
                text=True,
            )
            time.sleep(PLANNING_RESTART_DELAY_S)
            subprocess.run(
                ["tmux", "send-keys", "-t", PLANNING_TMUX_PANE, "C-u"],
                capture_output=True,
                check=True,
                text=True,
            )
            subprocess.run(
                [
                    "tmux",
                    "send-keys",
                    "-t",
                    PLANNING_TMUX_PANE,
                    PLANNING_TMUX_COMMAND,
                    "Enter",
                ],
                capture_output=True,
                check=True,
                text=True,
            )
            self.get_logger().info(
                f"Restarted planning command in tmux pane {PLANNING_TMUX_PANE}."
            )
        except Exception as exc:
            raise RuntimeError(f"Failed to start planning stack: {exc}") from exc

        time.sleep(PLANNING_STARTUP_DELAY_S)


def main() -> None:
    rclpy.init()
    node = MpcRespawnMonitor()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
