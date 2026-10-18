// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev The hook's six opening-fee exemption slots, all empty (only the developer is exempt).
function noExempt() pure returns (address[6] memory none) {}
