// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Append-only byte buffer with a fixed capacity: building a large SVG without quadratic copying.
library Buf {
    struct B {
        bytes data;
        uint256 len;
    }

    error Overflow();

    function init(uint256 capacity) internal pure returns (B memory b) {
        b.data = new bytes(capacity);
    }

    function add(B memory b, bytes memory s) internal pure {
        uint256 n = s.length;
        uint256 len = b.len;
        if (len + n > b.data.length) revert Overflow();
        bytes memory d = b.data;
        assembly ("memory-safe") {
            mcopy(add(add(d, 0x20), len), add(s, 0x20), n)
        }
        b.len = len + n;
    }

    function adds(B memory b, string memory s) internal pure {
        add(b, bytes(s));
    }

    function addByte(B memory b, uint8 c) internal pure {
        uint256 len = b.len;
        if (len + 1 > b.data.length) revert Overflow();
        b.data[len] = bytes1(c);
        b.len = len + 1;
    }

    /// @dev Shrinks the buffer to its content and returns it.
    function done(B memory b) internal pure returns (bytes memory out) {
        out = b.data;
        uint256 len = b.len;
        assembly ("memory-safe") {
            mstore(out, len)
        }
    }
}
