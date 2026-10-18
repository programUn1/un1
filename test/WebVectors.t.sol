// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ExactInputSingleV1, ExactInputCanonical, PathKey} from "./Fork.t.sol";

/// @notice Router calldata vectors for the website (web/tests/chain.test.mjs). The encodings are built exactly as the
///  fork tests that ran on the canonical Universal Router (`_routerSingle`, `test_fork_universalRouter_multiHop_ETH_UNI_UN1`),
///  for fixed inputs, and written to web/tests/router-vectors.json; the JS encoder must produce the same bytes.
contract WebVectorsTest is Test {
    address constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address constant TOKEN_ABOVE = 0x2222222222222222222222222222222222222222; // UNI is currency0
    address constant TOKEN_BELOW = 0x0101010101010101010101010101010101010101; // UNI is currency1
    address constant HOOK = 0x00000000000000000000000000000000000025cc;

    function _key(address token) internal pure returns (PoolKey memory k) {
        (address c0, address c1) = UNI < token ? (UNI, token) : (token, UNI);
        k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, 60, IHooks(HOOK));
    }

    function _single(PoolKey memory key, bool buy, uint128 amountIn, uint128 minOut) internal pure returns (bytes memory) {
        address token = Currency.unwrap(key.currency0) == UNI ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        bool uniIs0 = Currency.unwrap(key.currency0) == UNI;
        bool zeroForOne = buy == uniIs0;
        (address cin, address cout) = buy ? (UNI, token) : (token, UNI);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleV1(key, zeroForOne, amountIn, minOut, ""));
        params[1] = abi.encode(Currency.wrap(cin), uint256(amountIn));
        params[2] = abi.encode(Currency.wrap(cout), uint256(0));
        return abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);
    }

    function _multi(PoolKey memory key, uint128 amountIn, uint128 minOut) internal pure returns (bytes memory) {
        address token = Currency.unwrap(key.currency0) == UNI ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(Currency.wrap(UNI), 3000, 60, IHooks(address(0)), "");
        path[1] = PathKey(Currency.wrap(token), 0, 60, IHooks(HOOK), "");
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputCanonical(Currency.wrap(address(0)), path, new uint256[](0), amountIn, minOut));
        params[1] = abi.encode(Currency.wrap(address(0)), uint256(amountIn));
        params[2] = abi.encode(Currency.wrap(token), uint256(0));
        return abi.encode(abi.encodePacked(uint8(0x07), uint8(0x0c), uint8(0x0f)), params);
    }

    function test_writeRouterVectors() public {
        string memory out = "vectors";
        address[2] memory tokens = [TOKEN_ABOVE, TOKEN_BELOW];
        string[2] memory names = ["tokenAboveUni", "tokenBelowUni"];
        string memory json;
        for (uint256 i; i < 2; ++i) {
            PoolKey memory key = _key(tokens[i]);
            string memory o = names[i];
            vm.serializeAddress(o, "currency0", Currency.unwrap(key.currency0));
            vm.serializeAddress(o, "currency1", Currency.unwrap(key.currency1));
            vm.serializeAddress(o, "hooks", HOOK);
            vm.serializeBytes(o, "buyUni", _single(key, true, 20 ether, 150 ether));
            vm.serializeBytes(o, "sell", _single(key, false, 7 ether, 0.5 ether));
            json = vm.serializeBytes(o, "buyEth", _multi(key, 0.05 ether, 140 ether));
            json = vm.serializeString(out, names[i], json);
        }
        vm.writeJson(json, "../web/tests/router-vectors.json");
    }
}
