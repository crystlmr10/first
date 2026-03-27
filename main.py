from __future__ import annotations

import heapq
import json
import math
import os
from typing import Dict, List, Optional, Tuple
from urllib import error, parse, request

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Flood-aware routing backend (in-memory demo)
# Run with: uvicorn main:app --reload
# ---------------------------------------------------------------------------

app = FastAPI(title="Flood-Aware Routing API", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

IMPASSABLE_DEPTH = 50.0  # cm
RADIUS_CHECK_METERS = 150.0

# Nodes with lat/lng coordinates
nodes: Dict[str, Tuple[float, float]] = {
    "A": (10.297438, 123.876313),  # CIT-U (example start)
    "B": (10.297900, 123.877100),
    "C": (10.298500, 123.878000),
    "D": (10.299100, 123.878900),
    "E": (10.296900, 123.878200),
    "F": (10.296300, 123.877100),
}

# Adjacency list:
# (neighbor, distance_meters, flood_depth_cm, impassable_sign)
graph: Dict[str, List[Tuple[str, float, float, bool]]] = {
    "A": [("B", 120, 0, False), ("F", 150, 5, False)],
    "B": [("A", 120, 0, False), ("C", 130, 20, False), ("E", 150, 60, False)],
    "C": [("B", 130, 20, False), ("D", 120, 0, False)],
    "D": [("C", 120, 0, False), ("E", 140, 10, False)],
    "E": [("D", 140, 10, False), ("B", 150, 60, False), ("F", 110, 0, True)],
    "F": [("A", 150, 5, False), ("E", 110, 0, True)],
}


def _load_dotenv(dotenv_path: str = ".env") -> None:
    """
    Read key/value pairs from a local .env file.
    We only fill missing environment variables, so existing values stay untouched.
    """
    if not os.path.exists(dotenv_path):
        return

    try:
        with open(dotenv_path, "r", encoding="utf-8") as f:
            for raw_line in f:
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if key and key not in os.environ:
                    os.environ[key] = value
    except Exception as exc:
        print(f"[dotenv] failed to load {dotenv_path}: {exc}")


_load_dotenv()


class NodeInput(BaseModel):
    lat: float
    lng: float


class EdgeInput(BaseModel):
    to: str
    distance: float = Field(gt=0)
    flood_depth: float = 0.0
    impassable_sign: bool = False


class RouteRequest(BaseModel):
    start: str
    goal: str
    nodes: Dict[str, NodeInput]
    graph: Dict[str, List[EdgeInput]]


def _euclidean_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """
    Return approximate straight-line distance (in meters) between 2 coordinates.
    This is a simple estimate and is enough for this lightweight routing demo.
    """
    mean_lat_rad = math.radians((lat1 + lat2) / 2.0)
    meters_per_deg_lat = 111_320.0
    meters_per_deg_lng = 111_320.0 * math.cos(mean_lat_rad)
    dx = (lng2 - lng1) * meters_per_deg_lng
    dy = (lat2 - lat1) * meters_per_deg_lat
    return math.hypot(dx, dy)


def _to_xy_meters(lat: float, lng: float, ref_lat: float) -> Tuple[float, float]:
    """
    Convert latitude/longitude into local X/Y meter values
    so distance math is easier.
    """
    mean_lat_rad = math.radians(ref_lat)
    meters_per_deg_lat = 111_320.0
    meters_per_deg_lng = 111_320.0 * math.cos(mean_lat_rad)
    x = lng * meters_per_deg_lng
    y = lat * meters_per_deg_lat
    return x, y


def _point_to_segment_distance_meters(
    point: Tuple[float, float],
    seg_start: Tuple[float, float],
    seg_end: Tuple[float, float],
) -> float:
    """
    Return the shortest distance (meters) from one point
    to a road segment (line between two coordinates).
    """
    ref_lat = (point[0] + seg_start[0] + seg_end[0]) / 3.0
    px, py = _to_xy_meters(point[0], point[1], ref_lat)
    ax, ay = _to_xy_meters(seg_start[0], seg_start[1], ref_lat)
    bx, by = _to_xy_meters(seg_end[0], seg_end[1], ref_lat)

    abx, aby = bx - ax, by - ay
    apx, apy = px - ax, py - ay
    ab_len_sq = (abx * abx) + (aby * aby)
    if ab_len_sq == 0:
        return math.hypot(px - ax, py - ay)

    t = max(0.0, min(1.0, ((apx * abx) + (apy * aby)) / ab_len_sq))
    closest_x = ax + t * abx
    closest_y = ay + t * aby
    return math.hypot(px - closest_x, py - closest_y)


def heuristic(node_a: str, node_b: str, all_nodes: Dict[str, Tuple[float, float]]) -> float:
    """
    A* guess cost: "as-the-crow-flies" distance to the goal.
    This helps A* search faster in the right direction.
    """
    lat1, lng1 = all_nodes[node_a]
    lat2, lng2 = all_nodes[node_b]
    return _euclidean_meters(lat1, lng1, lat2, lng2)


def is_within_radius(
    point1: Tuple[float, float],
    point2: Tuple[float, float],
    radius_meters: float = RADIUS_CHECK_METERS,
) -> bool:
    """
    Quick check: is point1 inside the given meter radius of point2?
    """
    return _euclidean_meters(point1[0], point1[1], point2[0], point2[1]) <= radius_meters


def _edge_midpoint(u: str, v: str, all_nodes: Dict[str, Tuple[float, float]]) -> Tuple[float, float]:
    """Get the center coordinate of an edge between two nodes."""
    lat_u, lng_u = all_nodes[u]
    lat_v, lng_v = all_nodes[v]
    return ((lat_u + lat_v) / 2.0, (lng_u + lng_v) / 2.0)


def _is_flooded_edge(depth_cm: float, impassable_sign: bool) -> bool:
    """True when a road is unsafe due to flood depth or explicit impassable flag."""
    return depth_cm >= IMPASSABLE_DEPTH or impassable_sign


def _segment_within_radius_of_flood_point(
    u: str,
    v: str,
    hazard_point: Tuple[float, float],
    all_nodes: Dict[str, Tuple[float, float]],
    radius_meters: float = RADIUS_CHECK_METERS,
) -> bool:
    """
    True if any part of road segment (u->v) comes within the hazard radius
    of a flooded coordinate.
    """
    seg_start = all_nodes[u]
    seg_end = all_nodes[v]
    d = _point_to_segment_distance_meters(hazard_point, seg_start, seg_end)
    return d <= radius_meters


def is_impassable(
    current: str,
    nxt: str,
    depth_cm: float,
    impassable_sign: bool,
    all_nodes: Dict[str, Tuple[float, float]],
    adjacency: Dict[str, List[Tuple[str, float, float, bool]]],
) -> bool:
    """
    Decide if an edge is blocked during path search.
    Rule is simple here: if edge is already marked flooded/impassable, skip it.
    (Radius-based blocking is done earlier when we preprocess the graph.)
    """
    _ = (current, nxt, all_nodes, adjacency)  # keep signature stable for callers
    return _is_flooded_edge(depth_cm, impassable_sign)


def a_star(
    start: str,
    goal: str,
    adjacency: Dict[str, List[Tuple[str, float, float, bool]]],
    all_nodes: Dict[str, Tuple[float, float]],
    enforce_safety: bool = True,
) -> Optional[List[str]]:
    """
    Find a path from start to goal using custom A*.
    - Uses road distance as travel cost
    - Uses straight-line distance as guidance
    - Optionally skips unsafe edges for safety-first routing
    """
    open_heap: List[Tuple[float, str]] = []
    heapq.heappush(open_heap, (0.0, start))

    came_from: Dict[str, str] = {}
    g_score: Dict[str, float] = {node: float("inf") for node in all_nodes}
    g_score[start] = 0.0

    f_score: Dict[str, float] = {node: float("inf") for node in all_nodes}
    f_score[start] = heuristic(start, goal, all_nodes)

    visited = set()

    while open_heap:
        _, current = heapq.heappop(open_heap)
        if current in visited:
            continue
        visited.add(current)

        if current == goal:
            # Reconstruct path
            route = [current]
            while current in came_from:
                current = came_from[current]
                route.append(current)
            route.reverse()
            return route

        for neighbor, distance_m, depth_cm, sign in adjacency.get(current, []):
            if enforce_safety and is_impassable(
                current,
                neighbor,
                depth_cm,
                sign,
                all_nodes,
                adjacency,
            ):
                continue

            tentative_g = g_score[current] + distance_m
            if tentative_g < g_score[neighbor]:
                came_from[neighbor] = current
                g_score[neighbor] = tentative_g
                f_score[neighbor] = tentative_g + heuristic(neighbor, goal, all_nodes)
                heapq.heappush(open_heap, (f_score[neighbor], neighbor))

    return None


def check_route_for_impassable(
    route: List[str],
    adjacency: Dict[str, List[Tuple[str, float, float, bool]]],
    all_nodes: Dict[str, Tuple[float, float]],
) -> bool:
    """
    Safety check for a finished route.
    Returns True if at least one route segment is unsafe.
    """
    for i in range(len(route) - 1):
        u, v = route[i], route[i + 1]
        edge = next((e for e in adjacency.get(u, []) if e[0] == v), None)
        if edge is None:
            return True
        _, _, depth_cm, sign = edge
        if is_impassable(u, v, depth_cm, sign, all_nodes, adjacency):
            return True
    return False


def build_polyline(route: List[str], all_nodes: Dict[str, Tuple[float, float]]) -> List[Dict[str, float]]:
    """
    Convert route node IDs into ordered lat/lng points
    so the frontend can draw the polyline on the map.
    """
    return [{"lat": all_nodes[node][0], "lng": all_nodes[node][1]} for node in route]


def _fetch_supabase_flood_reports() -> List[Dict[str, object]]:
    """
    Fetch latest flood reports from Supabase REST API.
    Needs SUPABASE_URL and a key in environment variables.
    """
    supabase_url = os.getenv("SUPABASE_URL", "").strip().rstrip("/")
    supabase_key = (
        os.getenv("SUPABASE_ANON_KEY")
        or os.getenv("SUPABASE_KEY")
        or os.getenv("SUPABASE_SERVICE_ROLE_KEY")
        or ""
    ).strip()

    if not supabase_url or not supabase_key:
        print("[supabase] missing SUPABASE_URL or SUPABASE_ANON_KEY; using no flood reports")
        return []

    # Keep select fields minimal and safe; requesting non-existent columns causes 400.
    query = parse.urlencode(
        {
            "select": "latitude,longitude,admin_decision",
            "limit": "1000",
        }
    )
    endpoint = f"{supabase_url}/rest/v1/user_reports?{query}"

    req = request.Request(
        endpoint,
        method="GET",
        headers={
            "apikey": supabase_key,
            "Authorization": f"Bearer {supabase_key}",
            "Accept": "application/json",
        },
    )

    try:
        with request.urlopen(req, timeout=8) as resp:
            body = resp.read().decode("utf-8")
            data = json.loads(body)
            if isinstance(data, list):
                return data
    except error.HTTPError as exc:
        try:
            body = exc.read().decode("utf-8", errors="ignore")
        except Exception:
            body = ""
        print(f"[supabase] fetch failed: HTTP {exc.code} {exc.reason} body={body}")
    except error.URLError as exc:
        print(f"[supabase] fetch failed: {exc}")
    except Exception as exc:  # pragma: no cover - defensive parsing guard
        print(f"[supabase] unexpected error: {exc}")

    return []


def _report_depth_cm(report: Dict[str, object]) -> float:
    """Read flood depth from common field names and return it in centimeters."""
    for key in ("water_level_cm", "water_level", "depth_cm"):
        value = report.get(key)
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str):
            try:
                return float(value)
            except ValueError:
                pass
    return 0.0


def _as_float(value: object) -> Optional[float]:
    """Safely convert int/float/string to float; return None when conversion fails."""
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def _report_is_impassable(report: Dict[str, object]) -> bool:
    """True if report says impassable or depth is at/above the hard limit."""
    decision = str(report.get("admin_decision", "")).strip().lower()
    return decision == "impassable" or _report_depth_cm(report) >= IMPASSABLE_DEPTH


def _apply_supabase_flood_to_graph(
    adjacency: Dict[str, List[Tuple[str, float, float, bool]]],
    all_nodes: Dict[str, Tuple[float, float]],
    reports: List[Dict[str, object]],
) -> Dict[str, List[Tuple[str, float, float, bool]]]:
    """
    Create a safer copy of the graph:
    if an edge is within 150m of an impassable flood report,
    mark that edge as blocked.
    """
    hazards: List[Tuple[float, float]] = []
    for report in reports:
        lat = _as_float(report.get("latitude"))
        lng = _as_float(report.get("longitude"))
        if lat is None or lng is None:
            continue
        if _report_is_impassable(report):
            hazards.append((lat, lng))

    if not hazards:
        return adjacency

    updated: Dict[str, List[Tuple[str, float, float, bool]]] = {}
    blocked_edges = 0
    for u, neighbors in adjacency.items():
        new_neighbors: List[Tuple[str, float, float, bool]] = []
        for v, distance_m, depth_cm, sign in neighbors:
            blocked_by_report = any(
                _segment_within_radius_of_flood_point(u, v, hz, all_nodes)
                for hz in hazards
            )
            if blocked_by_report:
                blocked_edges += 1
                new_neighbors.append((v, distance_m, max(depth_cm, IMPASSABLE_DEPTH), True))
            else:
                new_neighbors.append((v, distance_m, depth_cm, sign))
        updated[u] = new_neighbors
    print(f"[supabase] hazards={len(hazards)} blocked_edges={blocked_edges}")
    return updated


def _solve_route(
    start: str,
    goal: str,
    adjacency: Dict[str, List[Tuple[str, float, float, bool]]],
    all_nodes: Dict[str, Tuple[float, float]],
) -> Dict[str, object]:
    """
    Shared route runner used by both GET and POST endpoints.
    It computes baseline route, safe route, validates result,
    and returns API-ready JSON with route + polyline.
    """
    if start not in all_nodes or goal not in all_nodes:
        raise HTTPException(status_code=400, detail="Invalid start or goal node.")
    if start == goal:
        route = [start]
        return {"status": "safe", "route": route, "polyline": build_polyline(route, all_nodes)}

    # Baseline route without safety constraints (for reroute detection).
    naive_route = a_star(start, goal, adjacency, all_nodes, enforce_safety=False)

    # Safety-first route.
    safe_route = a_star(start, goal, adjacency, all_nodes, enforce_safety=True)
    if not safe_route:
        return {"status": "no_route", "route": [], "polyline": []}

    status = "safe"
    if naive_route is not None and safe_route != naive_route:
        status = "rerouted"
        print(f"[reroute] Safer route selected: {safe_route} (was {naive_route})")

    # Post-validation: if unsafe segment still exists, recompute once more.
    if check_route_for_impassable(safe_route, adjacency, all_nodes):
        print("[reroute] Route validation detected unsafe segment, recomputing...")
        safe_route = a_star(start, goal, adjacency, all_nodes, enforce_safety=True)
        if not safe_route or check_route_for_impassable(safe_route, adjacency, all_nodes):
            return {"status": "no_route", "route": [], "polyline": []}
        status = "rerouted"

    return {"status": status, "route": safe_route, "polyline": build_polyline(safe_route, all_nodes)}


@app.get("/route")
def get_route(
    start: str = Query(..., description="Start node id (e.g. A)"),
    goal: str = Query(..., description="Goal node id (e.g. D)"),
):
    """Demo endpoint using built-in sample nodes/graph plus live flood reports."""
    reports = _fetch_supabase_flood_reports()
    graph_with_live_flood = _apply_supabase_flood_to_graph(graph, nodes, reports)
    return _solve_route(start, goal, graph_with_live_flood, nodes)


@app.post("/route")
def post_route(payload: RouteRequest):
    """
    Dynamic endpoint for Flutter/client apps.
    Client sends custom nodes + graph, backend injects live flood hazards,
    then returns a safe route and polyline.
    """
    dynamic_nodes: Dict[str, Tuple[float, float]] = {
        node_id: (node.lat, node.lng) for node_id, node in payload.nodes.items()
    }
    dynamic_graph: Dict[str, List[Tuple[str, float, float, bool]]] = {}
    for node_id, edges in payload.graph.items():
        dynamic_graph[node_id] = [
            (edge.to, edge.distance, edge.flood_depth, edge.impassable_sign) for edge in edges
        ]

    reports = _fetch_supabase_flood_reports()
    graph_with_live_flood = _apply_supabase_flood_to_graph(dynamic_graph, dynamic_nodes, reports)
    return _solve_route(payload.start, payload.goal, graph_with_live_flood, dynamic_nodes)
