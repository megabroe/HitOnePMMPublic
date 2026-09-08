// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IBuilderRegistry
/// @notice The only thing an H2 market needs from a builder registry: is this address an
/// eligible builder right now? The eligibility CRITERIA (stake token, amount, rules) live in
/// the registry implementation, not in the immutable market — so they can change by pointing a
/// new market at a new registry. A market calls `isBuilder` behind a try/catch, so a reverting
/// or hostile registry can never brick order execution; it just forfeits the builder share.
interface IBuilderRegistry {
    function isBuilder(address builder) external view returns (bool);
}
