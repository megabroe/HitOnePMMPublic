// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { EIP712 }     from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { H2Storage }  from "./H2Storage.sol";
import { H2Fallback } from "./H2Fallback.sol";

/// @title H2Market
/// @notice Concrete H2 exchange: ownerless and immutable — the constructor takes only the
/// settlement token and the H2Oracle it consumes. Everything else (markets, treasuries,
/// feeds) is created permissionlessly. See IH2Market and ORACLE_DESIGN.md.
contract H2Market is H2Fallback {
    constructor(address usdm_, address oracle_)
        H2Storage(usdm_, oracle_)
        EIP712("H2Market", "1")
    {}
}
