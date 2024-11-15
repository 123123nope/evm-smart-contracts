// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PausableOFTAdapter} from "./PausableOFTAdapter.sol";
import {ILBTC} from "../../LBTC/ILBTC.sol";

contract LBTCOFTAdapter is PausableOFTAdapter {
    constructor(
        address _token,
        address _lzEndpoint,
        address _owner
    ) OFTAdapter(_token, _lzEndpoint, _owner) Ownable(_owner) {}

    /**
     * @dev Burns locked LBTC to prevent ability to withdraw from adapter.
     */
    function halt() external onlyOwner whenPaused {
        ILBTC(address(innerToken)).burn(innerToken.balanceOf(address(this)));
    }
}
