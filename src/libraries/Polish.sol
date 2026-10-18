// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Polish
/// @notice Art v7: deterministic pixel rules applied to an owned part's v6 bitmap, byte for byte the same as
///  art/polish.py (itself checked cell by cell against the Codex play-lab engine). A part is 32 rows of 32 bits
///  (bit 31 = x 0): `cells` (present), `acc` (tone 2) and, for the eyes, `t3` (the recognition pixel, tone 3).
///  1. micro, from the part's 32-bit detail: add one edge cell and remove one (never splitting the part), or, for the
///     face and the muzzle, turn one main cell into an accent cell
///  2. lower mane: the gentle neck (outer cells below row 19 drawn toward x = 24)
///  3. Calm, Lash and Sleepy eyes: a neutral cell at (13, 14)
///  4. Notched ears: a one-cell bite on the front edge
library Polish {
    uint256 private constant FULL = 0xffffffff;

    struct Part {
        uint256[32] cells;
        uint256[32] acc;
        uint256[32] t3;
    }

    /// @dev The prototype's 32-bit hash (Math.imul arithmetic, mod 2^32).
    function rand(uint256 seed, uint256 salt) internal pure returns (uint256 h) {
        unchecked {
            h = (seed ^ ((salt + 1) * 0x9e3779b9)) & FULL;
            h = ((h ^ (h >> 16)) * 0x85ebca6b) & FULL;
            h = ((h ^ (h >> 13)) * 0xc2b2ae35) & FULL;
            h = (h ^ (h >> 16)) & FULL;
        }
    }

    function polish(uint256 part, uint256 shape, Part memory p, uint256 detail) internal pure {
        if (part == 3 || part == 4) _accent(part, p, detail);
        else _micro(part, p, detail);
        if (part == 6) _neck(p);
        if (part == 0 && (shape == 1 || shape == 3 || shape == 5)) {
            // Calm, Lash, Sleepy: the recognition cell
            p.cells[14] |= _bit(13);
            p.acc[14] &= ~_bit(13);
            p.t3[14] |= _bit(13);
        }
        if (part == 2 && shape == 5) _notch(p);
    }

    // ================= micro =================

    function _accent(uint256 part, Part memory p, uint256 seed) private pure {
        (uint256 x0, uint256 x1, uint256 y0, uint256 y1) = part == 3 ? (16, 19, 15, 20) : (5, 8, 19, 21);
        uint256 best = type(uint256).max;
        uint256 at = type(uint256).max;
        for (uint256 y = y0; y <= y1; ++y) {
            for (uint256 x = x0; x <= x1; ++x) {
                if (!_has(p.cells, x, y) || _has(p.acc, x, y)) continue;
                uint256 r = rand(seed, y * 32 + x + 710);
                if (r < best) (best, at) = (r, y * 32 + x);
            }
        }
        if (at != type(uint256).max) p.acc[at / 32] |= _bit(at % 32);
    }

    struct Ctx {
        uint256 part;
        uint256 seed;
        uint256[32] orig;
        uint256[32] origAcc;
        uint256 ax;
        uint256 ay;
    }

    function _micro(uint256 part, Part memory p, uint256 seed) private pure {
        Ctx memory c;
        c.part = part;
        c.seed = seed;
        for (uint256 y; y < 32; ++y) (c.orig[y], c.origAcc[y]) = (p.cells[y], p.acc[y]);
        (uint256 x0, uint256 x1, uint256 y0, uint256 y1) = _box(part);
        // the anchor: the edge cell with the lowest rank
        uint256 best = type(uint256).max;
        for (uint256 y = y0; y <= y1; ++y) {
            for (uint256 x = x0; x <= x1; ++x) {
                if (!_edge(c, x, y)) continue;
                uint256 r = rand(seed, y * 32 + x + 101);
                if (r < best) (best, c.ax, c.ay) = (r, x, y);
            }
        }
        if (best == type(uint256).max) return;
        _add(c, p);
        if (part != 0) _remove(c, p);
    }

    /// @dev Add the best empty cell near the anchor that touches the part (ties: the prototype's discovery order).
    function _add(Ctx memory c, Part memory p) private pure {
        uint256 best = type(uint256).max;
        uint256 bestDisc = type(uint256).max;
        uint256 at = type(uint256).max;
        for (uint256 k; k < 25; ++k) {
            int256 x = int256(c.ax) + int256(k % 5) - 2;
            int256 y = int256(c.ay) + int256(k / 5) - 2;
            if (x < 0 || y < 0 || x > 31 || y > 31) continue;
            (uint256 qx, uint256 qy) = (uint256(x), uint256(y));
            if (_dist(c, qx, qy) > 2 || _has(c.orig, qx, qy) || !_region(c.part, qx, qy)) continue;
            if (_count8(c.orig, qx, qy) < 2) continue;
            uint256 disc = _discovery(c.orig, qx, qy);
            if (disc == type(uint256).max) continue; // not next to the part
            uint256 r = rand(c.seed, qy * 32 + qx + 203);
            if (r < best || (r == best && disc < bestDisc)) (best, bestDisc, at) = (r, disc, qy * 32 + qx);
        }
        if (at == type(uint256).max) return;
        (uint256 ax, uint256 ay) = (at % 32, at / 32);
        p.cells[ay] |= _bit(ax);
        // tone of the first 4-neighbour (+x, -x, +y, -y) in the original part
        (bool found, uint256 nx, uint256 ny) = _firstNeighbour(c.orig, ax, ay);
        if (found && _has(c.origAcc, nx, ny)) p.acc[ay] |= _bit(ax);
    }

    /// @dev Remove one main-tone edge cell near the anchor, in rank order, unless it would split the part.
    function _remove(Ctx memory c, Part memory p) private pure {
        uint256 tried; // bitmask over the 25 cells around the anchor
        while (true) {
            uint256 best = type(uint256).max;
            uint256 bestPos = type(uint256).max;
            uint256 bestK;
            for (uint256 k; k < 25; ++k) {
                if ((tried >> k) & 1 == 1) continue;
                int256 x = int256(c.ax) + int256(k % 5) - 2;
                int256 y = int256(c.ay) + int256(k / 5) - 2;
                if (x < 0 || y < 0 || x > 31 || y > 31) continue;
                (uint256 qx, uint256 qy) = (uint256(x), uint256(y));
                if (_dist(c, qx, qy) > 2 || !_edge(c, qx, qy) || _has(c.origAcc, qx, qy)) continue;
                if (_count4(p.cells, qx, qy) < 2) continue;
                uint256 r = rand(c.seed, qy * 32 + qx + 301);
                uint256 pos = qy * 32 + qx;
                if (r < best || (r == best && pos < bestPos)) (best, bestPos, bestK) = (r, pos, k);
            }
            if (best == type(uint256).max) return;
            tried |= 1 << bestK;
            (uint256 rx, uint256 ry) = (bestPos % 32, bestPos / 32);
            p.cells[ry] &= ~_bit(rx);
            if (_staysConnected(p.cells, rx, ry)) {
                p.acc[ry] &= ~_bit(rx);
                return;
            }
            p.cells[ry] |= _bit(rx);
        }
    }

    /// @dev After removing (x, y): are all its 8-neighbours still in one 8-connected piece? (Then the number of
    ///      components did not grow; with no neighbour at all it shrank.)
    function _staysConnected(uint256[32] memory m, uint256 x, uint256 y) private pure returns (bool) {
        uint256[32] memory seen;
        uint256[32] memory want;
        bool any;
        for (uint256 k; k < 9; ++k) {
            if (k == 4) continue;
            int256 nx = int256(x) + int256(k % 3) - 1;
            int256 ny = int256(y) + int256(k / 3) - 1;
            if (nx < 0 || ny < 0 || nx > 31 || ny > 31) continue;
            if (!_has(m, uint256(nx), uint256(ny))) continue;
            want[uint256(ny)] |= _bit(uint256(nx));
            if (!any) seen[uint256(ny)] |= _bit(uint256(nx));
            any = true;
        }
        if (!any) return true;
        bool grew = true;
        while (grew) {
            grew = false;
            for (uint256 r; r < 32; ++r) {
                uint256 s = seen[r];
                uint256 spread = s | (s << 1) | (s >> 1);
                if (r > 0) spread |= seen[r - 1] | (seen[r - 1] << 1) | (seen[r - 1] >> 1);
                if (r < 31) spread |= seen[r + 1] | (seen[r + 1] << 1) | (seen[r + 1] >> 1);
                uint256 next = spread & m[r] & FULL;
                if (next != s) {
                    seen[r] = next;
                    grew = true;
                }
            }
        }
        for (uint256 r; r < 32; ++r) if (want[r] & ~seen[r] != 0) return false;
        return true;
    }

    // ================= neck, notch =================

    /// @dev Rows 21..31: for each target column 25..31 (t = 1..7) the source columns in order of preference (best
    ///      match first, as the prototype's nearest-source rule); row 20 (scale 0.95) maps every column to itself.
    function _neck(Part memory p) private pure {
        for (uint256 y = 21; y < 32; ++y) {
            uint256 table = y == 21 ? 0x10203040657000 : y == 22 ? 0x10203054607000 : y == 23 ? 0x10234050607000 : 0x10324050670000;
            uint256 row = p.cells[y];
            uint256 acc = p.acc[y];
            uint256 outRow = row & ~uint256(0x7f);
            uint256 outAcc = acc & ~uint256(0x7f);
            for (uint256 t = 1; t <= 7; ++t) {
                uint256 entry = (table >> (8 * (7 - t))) & 0xff;
                uint256 src = _present(row, entry >> 4) ? entry >> 4 : _present(row, entry & 15) ? entry & 15 : 0;
                if (src == 0) continue;
                outRow |= _bit(24 + t);
                if (_present(acc, src)) outAcc |= _bit(24 + t);
            }
            (p.cells[y], p.acc[y]) = (outRow, outAcc);
        }
    }

    function _present(uint256 row, uint256 k) private pure returns (bool) {
        return k != 0 && (row >> (7 - k)) & 1 == 1;
    }

    function _notch(Part memory p) private pure {
        // add (16,5) (17,5) (17,6) (16,7) (17,7) where missing, then cut (15,6) and (16,6). An added cell takes its
        // original tone; micro never removes an accent cell, so a missing cell here is always main tone.
        uint256 list = 0x1005110511061007110700; // x, y pairs
        for (uint256 k; k < 5; ++k) {
            uint256 x = (list >> (8 * (10 - 2 * k))) & 0xff;
            uint256 y = (list >> (8 * (9 - 2 * k))) & 0xff;
            p.cells[y] |= _bit(x);
        }
        p.cells[6] &= ~(_bit(15) | _bit(16));
        p.acc[6] &= ~(_bit(15) | _bit(16));
    }

    // ================= geometry =================

    function _bit(uint256 x) private pure returns (uint256) {
        return uint256(1) << (31 - x);
    }

    function _has(uint256[32] memory rows, uint256 x, uint256 y) private pure returns (bool) {
        return (rows[y] >> (31 - x)) & 1 == 1;
    }

    function _dist(Ctx memory c, uint256 x, uint256 y) private pure returns (uint256) {
        return (x > c.ax ? x - c.ax : c.ax - x) + (y > c.ay ? y - c.ay : c.ay - y);
    }

    /// @dev Present in the original part, in the part's region, not protected, with an in-bounds empty 4-neighbour.
    function _edge(Ctx memory c, uint256 x, uint256 y) private pure returns (bool) {
        if (!_has(c.orig, x, y) || !_region(c.part, x, y) || _protect(c.part, x, y)) return false;
        return (x < 31 && !_has(c.orig, x + 1, y)) || (x > 0 && !_has(c.orig, x - 1, y)) || (y < 31 && !_has(c.orig, x, y + 1))
            || (y > 0 && !_has(c.orig, x, y - 1));
    }

    function _count4(uint256[32] memory m, uint256 x, uint256 y) private pure returns (uint256 n) {
        if (x < 31 && _has(m, x + 1, y)) ++n;
        if (x > 0 && _has(m, x - 1, y)) ++n;
        if (y < 31 && _has(m, x, y + 1)) ++n;
        if (y > 0 && _has(m, x, y - 1)) ++n;
    }

    function _count8(uint256[32] memory m, uint256 x, uint256 y) private pure returns (uint256 n) {
        for (uint256 k; k < 9; ++k) {
            if (k == 4) continue;
            int256 nx = int256(x) + int256(k % 3) - 1;
            int256 ny = int256(y) + int256(k / 3) - 1;
            if (nx >= 0 && ny >= 0 && nx <= 31 && ny <= 31 && _has(m, uint256(nx), uint256(ny))) ++n;
        }
    }

    /// @dev The prototype adds candidates while scanning the part row-major, neighbours in the order +x, -x, +y, -y:
    ///      the first discovery of (x, y) is the smallest pos(p) * 4 + direction over the part cells p next to it.
    function _discovery(uint256[32] memory o, uint256 x, uint256 y) private pure returns (uint256 d) {
        d = type(uint256).max;
        if (x > 0 && _has(o, x - 1, y)) d = _min(d, (y * 32 + x - 1) * 4); // p = (x-1, y), direction +x
        if (x < 31 && _has(o, x + 1, y)) d = _min(d, (y * 32 + x + 1) * 4 + 1); // p = (x+1, y), direction -x
        if (y > 0 && _has(o, x, y - 1)) d = _min(d, ((y - 1) * 32 + x) * 4 + 2); // p = (x, y-1), direction +y
        if (y < 31 && _has(o, x, y + 1)) d = _min(d, ((y + 1) * 32 + x) * 4 + 3); // p = (x, y+1), direction -y
    }

    function _firstNeighbour(uint256[32] memory o, uint256 x, uint256 y) private pure returns (bool, uint256, uint256) {
        if (x < 31 && _has(o, x + 1, y)) return (true, x + 1, y);
        if (x > 0 && _has(o, x - 1, y)) return (true, x - 1, y);
        if (y < 31 && _has(o, x, y + 1)) return (true, x, y + 1);
        if (y > 0 && _has(o, x, y - 1)) return (true, x, y - 1);
        return (false, 0, 0);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Bounding box of the part's region.
    function _box(uint256 part) private pure returns (uint256, uint256, uint256, uint256) {
        if (part == 0) return (12, 15, 12, 14);
        if (part == 1) return (3, 13, 1, 7);
        if (part == 2) return (15, 20, 3, 7);
        if (part == 5) return (23, 30, 8, 14);
        if (part == 6) return (25, 30, 19, 30);
        return (16, 25, 23, 30); // swirl
    }

    function _region(uint256 part, uint256 x, uint256 y) private pure returns (bool) {
        if (part == 0) return x >= 12 && x <= 15 && y >= 12 && y <= 14 && !(x == 13 && y == 14);
        if (part == 1) return x >= 3 && x <= 13 && y >= 1 && y <= 7;
        if (part == 2) return x >= 15 && x <= 20 && y >= 3 && y <= 7;
        if (part == 5) return x >= 23 && x <= 30 && y >= 8 && y <= 14;
        if (part == 6) return (x >= 26 && x <= 30 && y >= 19 && y <= 22) || (x >= 25 && x <= 30 && y >= 25 && y <= 30);
        if (part == 7) return x >= 16 && x <= 25 && y >= 23 && y <= 30 && !(x >= 19 && x <= 22 && y >= 26 && y <= 28);
        return false;
    }

    function _protect(uint256 part, uint256 x, uint256 y) private pure returns (bool) {
        if (part == 0) return x == 13 && y == 14;
        if (part == 1) return x >= 10 && x <= 14 && y >= 8 && y <= 10;
        if (part == 2) return x >= 15 && x <= 19 && y >= 8 && y <= 9;
        if (part == 5) return y == 16 || x <= 20;
        if (part == 6) return y == 17 || x <= 24;
        if (part == 7) return x >= 19 && x <= 22 && y >= 26 && y <= 28;
        return true;
    }
}
