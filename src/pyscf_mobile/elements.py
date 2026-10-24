"""Periodic table data used by the molecule builder and the result views.

Single-bond covalent radii are from Cordero et al., Dalton Trans. (2008).
Electronegativities are Pauling values.  ``color`` is the CPK/Jmol hex colour
used to render atoms in the UI.
"""

from __future__ import annotations

from dataclasses import dataclass

# Z, symbol, name, atomic mass, covalent radius (A), Pauling EN, CPK colour
_RAW = (
    (1, "H", "Hydrogen", 1.008, 0.31, 2.20, "#FFFFFF"),
    (2, "He", "Helium", 4.0026, 0.28, None, "#D9FFFF"),
    (3, "Li", "Lithium", 6.94, 1.28, 0.98, "#CC80FF"),
    (4, "Be", "Beryllium", 9.0122, 0.96, 1.57, "#C2FF00"),
    (5, "B", "Boron", 10.81, 0.84, 2.04, "#FFB5B5"),
    (6, "C", "Carbon", 12.011, 0.76, 2.55, "#909090"),
    (7, "N", "Nitrogen", 14.007, 0.71, 3.04, "#3050F8"),
    (8, "O", "Oxygen", 15.999, 0.66, 3.44, "#FF0D0D"),
    (9, "F", "Fluorine", 18.998, 0.57, 3.98, "#90E050"),
    (10, "Ne", "Neon", 20.180, 0.58, None, "#B3E3F5"),
    (11, "Na", "Sodium", 22.990, 1.66, 0.93, "#AB5CF2"),
    (12, "Mg", "Magnesium", 24.305, 1.41, 1.31, "#8AFF00"),
    (13, "Al", "Aluminium", 26.982, 1.21, 1.61, "#BFA6A6"),
    (14, "Si", "Silicon", 28.085, 1.11, 1.90, "#F0C8A0"),
    (15, "P", "Phosphorus", 30.974, 1.07, 2.19, "#FF8000"),
    (16, "S", "Sulfur", 32.06, 1.05, 2.58, "#FFFF30"),
    (17, "Cl", "Chlorine", 35.45, 1.02, 3.16, "#1FF01F"),
    (18, "Ar", "Argon", 39.948, 1.06, None, "#80D1E3"),
    (19, "K", "Potassium", 39.098, 2.03, 0.82, "#8F40D4"),
    (20, "Ca", "Calcium", 40.078, 1.76, 1.00, "#3DFF00"),
    (21, "Sc", "Scandium", 44.956, 1.70, 1.36, "#E6E6E6"),
    (22, "Ti", "Titanium", 47.867, 1.60, 1.54, "#BFC2C7"),
    (23, "V", "Vanadium", 50.942, 1.53, 1.63, "#A6A6AB"),
    (24, "Cr", "Chromium", 51.996, 1.39, 1.66, "#8A99C7"),
    (25, "Mn", "Manganese", 54.938, 1.39, 1.55, "#9C7AC7"),
    (26, "Fe", "Iron", 55.845, 1.32, 1.83, "#E06633"),
    (27, "Co", "Cobalt", 58.933, 1.26, 1.88, "#F090A0"),
    (28, "Ni", "Nickel", 58.693, 1.24, 1.91, "#50D050"),
    (29, "Cu", "Copper", 63.546, 1.32, 1.90, "#C88033"),
    (30, "Zn", "Zinc", 65.38, 1.22, 1.65, "#7D80B0"),
    (31, "Ga", "Gallium", 69.723, 1.22, 1.81, "#C28F8F"),
    (32, "Ge", "Germanium", 72.630, 1.20, 2.01, "#668F8F"),
    (33, "As", "Arsenic", 74.922, 1.19, 2.18, "#BD80E3"),
    (34, "Se", "Selenium", 78.971, 1.20, 2.55, "#FFA100"),
    (35, "Br", "Bromine", 79.904, 1.20, 2.96, "#A62929"),
    (36, "Kr", "Krypton", 83.798, 1.16, 3.00, "#5CB8D1"),
    (37, "Rb", "Rubidium", 85.468, 2.20, 0.82, "#702EB0"),
    (38, "Sr", "Strontium", 87.62, 1.95, 0.95, "#00FF00"),
    (39, "Y", "Yttrium", 88.906, 1.90, 1.22, "#94FFFF"),
    (40, "Zr", "Zirconium", 91.224, 1.75, 1.33, "#94E0E0"),
    (41, "Nb", "Niobium", 92.906, 1.64, 1.60, "#73C2C9"),
    (42, "Mo", "Molybdenum", 95.95, 1.54, 2.16, "#54B5B5"),
    (43, "Tc", "Technetium", 98.0, 1.47, 1.90, "#3B9E9E"),
    (44, "Ru", "Ruthenium", 101.07, 1.46, 2.20, "#248F8F"),
    (45, "Rh", "Rhodium", 102.91, 1.42, 2.28, "#0A7D8C"),
    (46, "Pd", "Palladium", 106.42, 1.39, 2.20, "#006985"),
    (47, "Ag", "Silver", 107.87, 1.45, 1.93, "#C0C0C0"),
    (48, "Cd", "Cadmium", 112.41, 1.44, 1.69, "#FFD98F"),
    (49, "In", "Indium", 114.82, 1.42, 1.78, "#A67573"),
    (50, "Sn", "Tin", 118.71, 1.39, 1.96, "#668080"),
    (51, "Sb", "Antimony", 121.76, 1.39, 2.05, "#9E63B5"),
    (52, "Te", "Tellurium", 127.60, 1.38, 2.10, "#D47A00"),
    (53, "I", "Iodine", 126.90, 1.39, 2.66, "#940094"),
    (54, "Xe", "Xenon", 131.29, 1.40, 2.60, "#429EB0"),
    (55, "Cs", "Caesium", 132.91, 2.44, 0.79, "#57178F"),
    (56, "Ba", "Barium", 137.33, 2.15, 0.89, "#00C900"),
    (57, "La", "Lanthanum", 138.91, 2.07, 1.10, "#70D4FF"),
    (58, "Ce", "Cerium", 140.12, 2.04, 1.12, "#FFFFC7"),
    (59, "Pr", "Praseodymium", 140.91, 2.03, 1.13, "#D9FFC7"),
    (60, "Nd", "Neodymium", 144.24, 2.01, 1.14, "#C7FFC7"),
    (61, "Pm", "Promethium", 145.0, 1.99, None, "#A3FFC7"),
    (62, "Sm", "Samarium", 150.36, 1.98, 1.17, "#8FFFC7"),
    (63, "Eu", "Europium", 151.96, 1.98, None, "#61FFC7"),
    (64, "Gd", "Gadolinium", 157.25, 1.96, 1.20, "#45FFC7"),
    (65, "Tb", "Terbium", 158.93, 1.94, None, "#30FFC7"),
    (66, "Dy", "Dysprosium", 162.50, 1.92, 1.22, "#1FFFC7"),
    (67, "Ho", "Holmium", 164.93, 1.92, 1.23, "#00FF9C"),
    (68, "Er", "Erbium", 167.26, 1.89, 1.24, "#00E675"),
    (69, "Tm", "Thulium", 168.93, 1.90, 1.25, "#00D452"),
    (70, "Yb", "Ytterbium", 173.05, 1.87, None, "#00BF38"),
    (71, "Lu", "Lutetium", 174.97, 1.87, 1.27, "#00AB24"),
    (72, "Hf", "Hafnium", 178.49, 1.75, 1.30, "#4DC2FF"),
    (73, "Ta", "Tantalum", 180.95, 1.70, 1.50, "#4DA6FF"),
    (74, "W", "Tungsten", 183.84, 1.62, 2.36, "#2194D6"),
    (75, "Re", "Rhenium", 186.21, 1.51, 1.90, "#267DAB"),
    (76, "Os", "Osmium", 190.23, 1.44, 2.20, "#266696"),
    (77, "Ir", "Iridium", 192.22, 1.41, 2.20, "#175487"),
    (78, "Pt", "Platinum", 195.08, 1.36, 2.28, "#D0D0E0"),
    (79, "Au", "Gold", 196.97, 1.36, 2.54, "#FFD123"),
    (80, "Hg", "Mercury", 200.59, 1.32, 2.00, "#B8B8D0"),
    (81, "Tl", "Thallium", 204.38, 1.45, 1.62, "#A6544D"),
    (82, "Pb", "Lead", 207.2, 1.46, 2.33, "#575961"),
    (83, "Bi", "Bismuth", 208.98, 1.48, 2.02, "#9E4FB5"),
    (84, "Po", "Polonium", 209.0, 1.40, 2.00, "#AB5C00"),
    (85, "At", "Astatine", 210.0, 1.50, 2.20, "#754F45"),
    (86, "Rn", "Radon", 222.0, 1.50, None, "#428296"),
)


@dataclass(frozen=True)
class Element:
    z: int
    symbol: str
    name: str
    mass: float
    covalent_radius: float
    electronegativity: float | None
    color: str

    def as_dict(self) -> dict:
        return {
            "z": self.z,
            "symbol": self.symbol,
            "name": self.name,
            "mass": self.mass,
            "covalentRadius": self.covalent_radius,
            "electronegativity": self.electronegativity,
            "color": self.color,
        }


ELEMENTS: tuple[Element, ...] = tuple(Element(*row) for row in _RAW)
BY_SYMBOL: dict[str, Element] = {e.symbol: e for e in ELEMENTS}
BY_Z: dict[int, Element] = {e.z: e for e in ELEMENTS}


def resolve(token: str | int) -> Element:
    """Look up an element by symbol (case-insensitive) or atomic number."""
    if isinstance(token, int):
        return BY_Z[token]
    text = str(token).strip()
    if text.isdigit():
        return BY_Z[int(text)]
    key = text.capitalize()
    if key not in BY_SYMBOL:
        raise KeyError(f"unknown element: {token!r}")
    return BY_SYMBOL[key]


def all_elements() -> list[dict]:
    return [e.as_dict() for e in ELEMENTS]
