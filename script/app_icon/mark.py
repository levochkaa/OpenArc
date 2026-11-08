"""The OpenArc mark: an arch over a shorter leg, as SVG path data.

Coordinates are in a 1020 x 600 box, y down. The legs are straight and share
one slope; each curve is one cubic Bezier fitted to the reference drawing,
leaving and meeting the straight edges along their direction. The feet have
small rounded corners and the arch ends in a point on the left.
"""

import math

WIDTH, HEIGHT = 1020, 600
BOTTOM = 567
FOOT_RADIUS = 11


def _toward(a, b, distance):
    length = math.dist(a, b)
    return (a[0] + (b[0] - a[0]) * distance / length, a[1] + (b[1] - a[1]) * distance / length)


def _corner(previous, corner, following, radius=FOOT_RADIUS):
    """Line to just before `corner`, then a quadratic round over it."""
    start = _toward(corner, previous, radius)
    end = _toward(corner, following, radius)
    return [f"L {start[0]:.2f},{start[1]:.2f}", f"Q {corner[0]},{corner[1]} {end[0]:.2f},{end[1]:.2f}"]


def leg():
    """The shorter left leg, its top cut along the arch."""
    bottom_left, bottom_right = (33, BOTTOM), (268, BOTTOM)
    d = [
        "M 195,300",
        "C 220.8,257.4 278.9,225.0 330,225",
        "C 359.5,225.0 453.0,257.2 453,282",
        "C 453.0,288.1 431.4,300.8 424,313",
    ]
    d += _corner((424, 313), bottom_right, bottom_left)
    d += _corner(bottom_right, bottom_left, (195, 300))
    d.append("Z")
    return " ".join(d)


def arch():
    """The arch from its pointed tip over to the right foot."""
    inner_foot, outer_foot = (746, BOTTOM), (981, BOTTOM)
    d = [
        "M 584,300",
        "C 537.8,223.9 447.6,165.0 360,165",
        "C 325.2,165.0 305.2,170.0 273,178",
        "C 313.0,89.1 408.1,26.0 508,26",
        "C 615.1,26.0 684.6,80.1 738,168",
    ]
    d += _corner((738, 168), outer_foot, inner_foot)
    d += _corner(outer_foot, inner_foot, (584, 300))
    d.append("Z")
    return " ".join(d)
