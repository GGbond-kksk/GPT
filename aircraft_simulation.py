"""Aircraft motion simulation and visualization.

This script loads a wavefront OBJ model of an aircraft, simulates common
maneuvers (level flight, coordinated turn, climb, roll, dive) according to a
sequence of flight segments, and visualizes the motion using matplotlib's 3D
animation tools.

The implementation focuses on simple kinematics that are sufficient for
illustrating typical trajectories.  It outputs the aircraft position,
forward-heading vector, and roll angle at each simulation step, and displays an
animation of the aircraft moving along the computed path.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple

import math
import numpy as np
from matplotlib import pyplot as plt
from matplotlib import animation
from mpl_toolkits.mplot3d.art3d import Poly3DCollection


Vector = np.ndarray


@dataclass
class FlightSegment:
    """Represents a portion of the trajectory with a single motion type."""

    state: str
    duration: float
    params: Dict[str, float] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.duration <= 0:
            raise ValueError("Segment duration must be positive")
        self.state = self.state.lower()


class ObjModel:
    """Simple OBJ loader that supports vertices and triangular faces."""

    def __init__(self, vertices: np.ndarray, faces: List[List[int]]):
        self.vertices = vertices.astype(float)
        self.faces = faces

    @classmethod
    def load(cls, path: Path) -> "ObjModel":
        vertices: List[List[float]] = []
        faces: List[List[int]] = []
        with path.open("r", encoding="utf-8") as obj_file:
            for line in obj_file:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split()
                if parts[0] == "v" and len(parts) >= 4:
                    vertices.append([float(parts[1]), float(parts[2]), float(parts[3])])
                elif parts[0] == "f" and len(parts) >= 4:
                    face_indices = []
                    for part in parts[1:4]:
                        idx = part.split("/")[0]
                        face_indices.append(int(idx) - 1)
                    faces.append(face_indices)
        if not vertices or not faces:
            raise ValueError("OBJ model must contain at least one vertex and face")
        return cls(np.array(vertices), faces)


def normalize(vec: Vector) -> Vector:
    norm = np.linalg.norm(vec)
    if norm < 1e-9:
        raise ValueError("Cannot normalize near-zero vector")
    return vec / norm


def rotate_vector(vec: Vector, axis: Vector, angle: float) -> Vector:
    """Rotate vec around axis by angle (radians) using Rodrigues' rotation."""
    axis = normalize(axis)
    cos_theta = math.cos(angle)
    sin_theta = math.sin(angle)
    return (
        vec * cos_theta
        + np.cross(axis, vec) * sin_theta
        + axis * np.dot(axis, vec) * (1 - cos_theta)
    )


def compute_orientation(forward: Vector, roll_angle: float, up_reference: Vector) -> np.ndarray:
    """Construct an orientation matrix from forward direction and roll angle."""
    forward = normalize(forward)
    up_ref = normalize(up_reference)
    if abs(np.dot(forward, up_ref)) > 0.99:
        # Forward is close to the reference up axis; choose an alternative up.
        up_ref = np.array([0.0, 1.0, 0.0])
    right = np.cross(forward, up_ref)
    if np.linalg.norm(right) < 1e-6:
        right = np.array([1.0, 0.0, 0.0])
    right = normalize(right)
    up = np.cross(right, forward)
    up = normalize(up)

    if abs(roll_angle) > 1e-8:
        right = rotate_vector(right, forward, roll_angle)
        up = rotate_vector(up, forward, roll_angle)

    orientation = np.column_stack((forward, right, up))
    return orientation


def state_name(name: str) -> str:
    """Normalize state names to English keywords."""
    mapping = {
        "平飞": "level",
        "level": "level",
        "盘旋": "turn",
        "turn": "turn",
        "跃升": "climb",
        "climb": "climb",
        "滚装": "roll",
        "roll": "roll",
        "俯冲": "dive",
        "dive": "dive",
    }
    try:
        return mapping[name.lower()]
    except KeyError as exc:
        raise ValueError(f"Unsupported flight state: {name}") from exc


@dataclass
class SimulationResult:
    positions: np.ndarray
    headings: np.ndarray
    roll_angles: np.ndarray
    orientations: np.ndarray
    times: np.ndarray


def simulate_flight(
    segments: Sequence[FlightSegment],
    *,
    initial_position: Iterable[float],
    initial_heading: Iterable[float],
    speed: float,
    acceleration: float,
    default_turn_radius: float,
    default_roll_rate: float,
    default_climb_height: float,
    default_dive_height: float,
    dt: float,
    steps: int,
) -> SimulationResult:
    """Simulate aircraft motion following the provided segments."""

    if steps <= 1:
        raise ValueError("Number of steps must be greater than 1")
    if dt <= 0:
        raise ValueError("Time step must be positive")

    total_segment_time = sum(seg.duration for seg in segments)
    total_time = dt * (steps - 1)
    if not math.isclose(total_segment_time, total_time, rel_tol=1e-3, abs_tol=1e-3):
        raise ValueError(
            "Sum of segment durations must match total simulation time (dt * (steps - 1))"
        )

    pos = np.array(initial_position, dtype=float)
    forward = normalize(np.array(initial_heading, dtype=float))
    roll_angle = 0.0
    current_speed = float(speed)
    up_reference = np.array([0.0, 0.0, 1.0])

    positions = np.zeros((steps, 3))
    headings = np.zeros((steps, 3))
    roll_angles = np.zeros(steps)
    orientations = np.zeros((steps, 3, 3))
    times = np.linspace(0.0, total_time, steps)

    g = 9.81
    seg_index = 0
    seg_elapsed = 0.0
    current_segment = segments[seg_index]

    for i in range(steps):
        state = state_name(current_segment.state)
        positions[i] = pos
        headings[i] = forward
        roll_angles[i] = roll_angle
        orientations[i] = compute_orientation(forward, roll_angle, up_reference)

        # Skip dynamics update on last stored frame.
        if i == steps - 1:
            break

        # Update speed according to acceleration.
        current_speed = max(0.0, current_speed + acceleration * dt)
        velocity_vector = forward * current_speed

        if state == "level":
            # Force level flight by removing vertical component.
            horizontal = forward.copy()
            horizontal[2] = 0.0
            if np.linalg.norm(horizontal) < 1e-6:
                horizontal = np.array([1.0, 0.0, 0.0])
            forward = normalize(horizontal)
            roll_angle *= 0.95
            velocity_vector = forward * current_speed

        elif state == "turn":
            radius = current_segment.params.get("radius", default_turn_radius)
            if radius <= 0:
                raise ValueError("Turn radius must be positive")
            direction = np.sign(current_segment.params.get("direction", 1.0)) or 1.0
            yaw_rate = direction * current_speed / radius
            forward = rotate_vector(forward, up_reference, yaw_rate * dt)
            forward[2] = 0.0
            forward = normalize(forward)
            velocity_vector = forward * current_speed
            bank_angle = math.atan2(current_speed**2, g * radius)
            roll_angle = bank_angle * direction

        elif state == "climb":
            height = current_segment.params.get("height", default_climb_height)
            duration = current_segment.duration
            vertical_speed = height / duration
            max_vertical = 0.95 * current_speed
            vertical_speed = float(np.clip(vertical_speed, -max_vertical, max_vertical))
            horizontal_speed = math.sqrt(max(current_speed**2 - vertical_speed**2, 0.0))
            horizontal = forward.copy()
            horizontal[2] = 0.0
            if np.linalg.norm(horizontal) < 1e-6:
                horizontal = np.array([1.0, 0.0, 0.0])
            horizontal_dir = normalize(horizontal)
            velocity_vector = horizontal_dir * horizontal_speed + up_reference * vertical_speed
            forward = normalize(velocity_vector)
            roll_angle *= 0.9

        elif state == "dive":
            height = current_segment.params.get("height", default_dive_height)
            duration = current_segment.duration
            vertical_speed = -abs(height) / duration
            max_vertical = 0.95 * current_speed
            vertical_speed = float(np.clip(vertical_speed, -max_vertical, max_vertical))
            horizontal_speed = math.sqrt(max(current_speed**2 - vertical_speed**2, 0.0))
            horizontal = forward.copy()
            horizontal[2] = 0.0
            if np.linalg.norm(horizontal) < 1e-6:
                horizontal = np.array([1.0, 0.0, 0.0])
            horizontal_dir = normalize(horizontal)
            velocity_vector = horizontal_dir * horizontal_speed + up_reference * vertical_speed
            forward = normalize(velocity_vector)
            roll_angle *= 0.9

        elif state == "roll":
            rate = current_segment.params.get("roll_rate", default_roll_rate)
            roll_angle += rate * dt
            velocity_vector = forward * current_speed

        else:
            raise AssertionError(f"Unhandled flight state: {state}")

        pos = pos + velocity_vector * dt

        seg_elapsed += dt
        if seg_elapsed >= current_segment.duration - 1e-9 and seg_index < len(segments) - 1:
            seg_index += 1
            current_segment = segments[seg_index]
            seg_elapsed = 0.0

    return SimulationResult(positions, headings, roll_angles, orientations, times)


def set_axes_equal(ax: plt.Axes) -> None:
    """Set 3D plot axes to equal scale."""
    limits = np.array([
        ax.get_xlim3d(),
        ax.get_ylim3d(),
        ax.get_zlim3d(),
    ])
    centers = np.mean(limits, axis=1)
    radius = 0.5 * np.max(limits[:, 1] - limits[:, 0])
    ax.set_xlim3d([centers[0] - radius, centers[0] + radius])
    ax.set_ylim3d([centers[1] - radius, centers[1] + radius])
    ax.set_zlim3d([centers[2] - radius, centers[2] + radius])


def animate_simulation(
    model: ObjModel,
    result: SimulationResult,
    *,
    interval: int = 50,
    save_path: Path | None = None,
) -> animation.FuncAnimation:
    """Create and optionally save an animation of the simulated motion."""
    positions = result.positions
    orientations = result.orientations
    times = result.times

    fig = plt.figure(figsize=(8, 6))
    ax = fig.add_subplot(111, projection="3d")
    ax.set_xlabel("X (m)")
    ax.set_ylabel("Y (m)")
    ax.set_zlabel("Z (m)")
    ax.set_title("Aircraft Motion Simulation")

    vertices = model.vertices
    faces = model.faces
    mesh = Poly3DCollection(
        [], facecolor="lightgray", edgecolor="black", linewidth=0.2, alpha=0.9
    )
    ax.add_collection3d(mesh)

    path_line, = ax.plot([], [], [], color="tab:blue", lw=1.5, label="Flight Path")

    # Heading/right/up orientation axes for visualization of attitude changes.
    axis_scale = max(np.linalg.norm(vertices, axis=1).max(), 1.0)
    forward_axis, = ax.plot([], [], [], color="tab:red", lw=1.2, label="Heading")
    right_axis, = ax.plot([], [], [], color="tab:green", lw=1.2, label="Right")
    up_axis, = ax.plot([], [], [], color="tab:purple", lw=1.2, label="Up")
    roll_text = ax.text2D(0.02, 0.95, "", transform=ax.transAxes)

    ax.legend(loc="upper left")

    # Pre-compute bounding box to set axes limits.
    model_extent = np.max(np.linalg.norm(vertices, axis=1))
    margin = max(model_extent, 1.0)
    mins = positions.min(axis=0) - margin
    maxs = positions.max(axis=0) + margin
    ax.set_xlim(mins[0], maxs[0])
    ax.set_ylim(mins[1], maxs[1])
    ax.set_zlim(mins[2], maxs[2])
    set_axes_equal(ax)

    def update(frame: int):
        pos = positions[frame]
        orientation = orientations[frame]
        transformed = (orientation @ vertices.T).T + pos
        mesh.set_verts([transformed[face] for face in faces])
        path_line.set_data(positions[: frame + 1, 0], positions[: frame + 1, 1])
        path_line.set_3d_properties(positions[: frame + 1, 2])

        # Update orientation axes to highlight attitude changes.
        origin = pos
        forward_dir = orientation[:, 0]
        right_dir = orientation[:, 1]
        up_dir = orientation[:, 2]
        forward_axis.set_data(
            [origin[0], origin[0] + forward_dir[0] * axis_scale],
            [origin[1], origin[1] + forward_dir[1] * axis_scale],
        )
        forward_axis.set_3d_properties(
            [origin[2], origin[2] + forward_dir[2] * axis_scale]
        )
        right_axis.set_data(
            [origin[0], origin[0] + right_dir[0] * axis_scale],
            [origin[1], origin[1] + right_dir[1] * axis_scale],
        )
        right_axis.set_3d_properties([origin[2], origin[2] + right_dir[2] * axis_scale])
        up_axis.set_data(
            [origin[0], origin[0] + up_dir[0] * axis_scale],
            [origin[1], origin[1] + up_dir[1] * axis_scale],
        )
        up_axis.set_3d_properties([origin[2], origin[2] + up_dir[2] * axis_scale])

        roll_text.set_text(f"Roll: {result.roll_angles[frame]:.2f} rad")
        ax.set_title(f"Aircraft Motion Simulation\nTime = {times[frame]:.2f} s")
        return mesh, path_line, forward_axis, right_axis, up_axis, roll_text

    anim = animation.FuncAnimation(
        fig,
        update,
        frames=len(positions),
        interval=interval,
        blit=False,
        repeat=False,
    )

    if save_path is not None:
        anim.save(str(save_path))
    return anim


def print_summary(result: SimulationResult) -> None:
    """Print table of position, heading, and roll angle for each time step."""
    header = f"{'Step':>4} {'Time(s)':>8} {'X(m)':>10} {'Y(m)':>10} {'Z(m)':>10}"
    header += f" {'HeadingX':>10} {'HeadingY':>10} {'HeadingZ':>10} {'Roll(rad)':>10}"
    print(header)
    for idx, (time, pos, heading, roll_angle) in enumerate(
        zip(result.times, result.positions, result.headings, result.roll_angles)
    ):
        print(
            f"{idx:4d} {time:8.2f} {pos[0]:10.3f} {pos[1]:10.3f} {pos[2]:10.3f}"
            f" {heading[0]:10.3f} {heading[1]:10.3f} {heading[2]:10.3f} {roll_angle:10.3f}"
        )


def demo_configuration() -> Tuple[ObjModel, SimulationResult]:
    """Run a demonstration simulation with placeholder data."""
    # The demo uses a simple triangular prism model as a stand-in if no OBJ is provided.
    # Users should replace this with an actual aircraft model path.
    demo_vertices = np.array(
        [
            [1.5, 0.0, 0.0],
            [-1.0, 0.6, 0.2],
            [-1.0, -0.6, 0.2],
            [-1.0, 0.6, -0.2],
            [-1.0, -0.6, -0.2],
        ]
    )
    demo_faces = [[0, 1, 2], [0, 2, 4], [0, 4, 3], [0, 3, 1], [1, 2, 4], [1, 4, 3]]
    model = ObjModel(demo_vertices, demo_faces)

    segments = [
        FlightSegment("平飞", duration=5.0),
        FlightSegment("盘旋", duration=8.0, params={"radius": 100.0, "direction": 1}),
        FlightSegment("跃升", duration=6.0, params={"height": 200.0}),
        FlightSegment("滚装", duration=4.0, params={"roll_rate": math.radians(45)}),
        FlightSegment("俯冲", duration=6.0, params={"height": 150.0}),
        FlightSegment("平飞", duration=5.0),
    ]

    dt = 0.5
    steps = int(sum(seg.duration for seg in segments) / dt) + 1

    result = simulate_flight(
        segments,
        initial_position=(0.0, 0.0, 1000.0),
        initial_heading=(1.0, 0.0, 0.0),
        speed=120.0,
        acceleration=0.0,
        default_turn_radius=150.0,
        default_roll_rate=math.radians(30.0),
        default_climb_height=150.0,
        default_dive_height=150.0,
        dt=dt,
        steps=steps,
    )
    return model, result


def main() -> None:
    model, result = demo_configuration()
    print_summary(result)
    anim = animate_simulation(model, result)
    plt.show()


if __name__ == "__main__":
    main()
