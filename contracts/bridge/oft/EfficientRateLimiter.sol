// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title RateLimiter
 * @dev Abstract contract for implementing net rate limiting functionality.  This effectively allows two operations to
 * offset each others net impact (e.g., inflow v.s. outflow of assets).  It is designed to be inherited by other
 * contracts requiring rate limiting capabilities to protect resources or services from excessive use.
 * @dev A flexible rate limit that grows during congestive periods and shrinks during calm periods could give some
 * leeway when someone tries to forcefully congest the network, while still preventing huge amounts to be sent at once.
 */
abstract contract EfficientRateLimiter {
    /**
     * @notice Rate Limit struct.
     * @param amountInFlight Current amount within the rate limit window.
     * @param lastUpdated Timestamp representing the last time the rate limit was checked or updated.
     * @param limit This represents the maximum allowed amount within a given window.
     * @param window Defines the duration of the rate limiting window.
     */
    struct RateLimit {
        uint256 amountInFlight;
        uint256 lastUpdated;
        uint256 limit;
        uint256 window;
    }

    // Tracks rate limits for outbound transactions to a dstEid.
    mapping(uint32 dstEid => RateLimit limit) public outboundRateLimits;
    // Tracks rate limits for inbound transactions from a srcEid.
    mapping(uint32 srcEid => RateLimit limit) public inboundRateLimits;

    /**
     * @notice Rate Limit Configuration struct.
     * @param dstEid The destination endpoint id.
     * @param limit This represents the maximum allowed amount within a given window.
     * @param window Defines the duration of the rate limiting window.
     */
    struct RateLimitConfig {
        uint32 eid;
        uint256 limit;
        uint256 window;
    }

    // Define an enum to clearly distinguish between inbound and outbound rate limits.
    enum RateLimitDirection {
        Inbound,
        Outbound
    }

    /**
     * @notice Emitted when _setRateLimits occurs.
     * @param rateLimitConfigs An array of `RateLimitConfig` structs representing the rate limit configurations set per endpoint id.
     * - `eid`: The source / destination endpoint id (depending on direction).
     * - `limit`: This represents the maximum allowed amount within a given window.
     * - `window`: Defines the duration of the rate limiting window.
     * @param direction Specifies whether the outbound or inbound rates were changed.
     */
    event RateLimitsChanged(
        RateLimitConfig[] rateLimitConfigs,
        RateLimitDirection direction
    );

    /**
     * @notice Error that is thrown when an amount exceeds the rate_limit for a given direction.
     */
    error RateLimitExceeded();

    /**
     * @notice Get the current amount that can be sent to this destination endpoint id for the given rate limit window.
     * @param _dstEid The destination endpoint id.
     * @return currentAmountInFlight The current amount that was sent in this window.
     * @return amountCanBeSent The amount that can be sent.
     */
    function getAmountCanBeSent(
        uint32 _dstEid
    )
        external
        view
        virtual
        returns (uint256 currentAmountInFlight, uint256 amountCanBeSent)
    {
        RateLimit storage orl = outboundRateLimits[_dstEid];
        return
            _amountCanBeSent(
                orl.amountInFlight,
                orl.lastUpdated,
                orl.limit,
                orl.window
            );
    }

    /**
     * @notice Get the current amount that can be received from the source endpoint id for the given rate limit window.
     * @param _srcEid The source endpoint id.
     * @return currentAmountInFlight The current amount that has been received in this window.
     * @return amountCanBeReceived The amount that can be received.
     */
    function getAmountCanBeReceived(
        uint32 _srcEid
    )
        external
        view
        virtual
        returns (uint256 currentAmountInFlight, uint256 amountCanBeReceived)
    {
        RateLimit storage irl = inboundRateLimits[_srcEid];
        return
            _amountCanBeReceived(
                irl.amountInFlight,
                irl.lastUpdated,
                irl.limit,
                irl.window
            );
    }

    /**
     * @notice Sets the Rate Limits.
     * @param _rateLimitConfigs A `RateLimitConfig[]` array representing the rate limit configurations for either outbound or inbound.
     * @param direction Indicates whether the rate limits being set are for outbound or inbound.
     */
    function _setRateLimits(
        RateLimitConfig[] memory _rateLimitConfigs,
        RateLimitDirection direction
    ) internal virtual {
        for (uint256 i = 0; i < _rateLimitConfigs.length; i++) {
            RateLimit storage rateLimit = direction ==
                RateLimitDirection.Outbound
                ? outboundRateLimits[_rateLimitConfigs[i].eid]
                : inboundRateLimits[_rateLimitConfigs[i].eid];

            // Checkpoint the existing rate limit to not retroactively apply the new decay rate.
            _checkAndUpdateRateLimit(_rateLimitConfigs[i].eid, 0, direction);

            // Does NOT reset the amountInFlight/lastUpdated of an existing rate limit.
            rateLimit.limit = _rateLimitConfigs[i].limit;
            rateLimit.window = _rateLimitConfigs[i].window;
        }
        emit RateLimitsChanged(_rateLimitConfigs, direction);
    }

    /**
     * @dev Calculates the current amount in flight and the available capacity based on the rate limit configuration and time elapsed.
     * This function applies a linear decay model to compute how much of the 'amountInFlight' remains based on the time elapsed since the last update.
     * @param _amountInFlight The total amount that was in flight at the last update.
     * @param _lastUpdated The timestamp (in seconds) when the last update occurred.
     * @param _limit The maximum allowable amount within the specified window.
     * @param _window The time window (in seconds) for which the limit applies.
     * @return currentAmountInFlight The decayed amount of in-flight based on the elapsed time since lastUpdated. If the time since lastUpdated exceeds the window, it returns zero.
     * @return availableCapacity The amount of capacity available for new activity. If the time since lastUpdated exceeds the window, it returns the full limit.
     */
    function _calculateDecay(
        uint256 _amountInFlight,
        uint256 _lastUpdated,
        uint256 _limit,
        uint256 _window
    )
        internal
        view
        returns (uint256 currentAmountInFlight, uint256 availableCapacity)
    {
        uint256 timeSinceLastUpdate = block.timestamp - _lastUpdated;
        if (timeSinceLastUpdate >= _window) {
            return (0, _limit);
        } else {
            uint256 decay = (_limit * timeSinceLastUpdate) / _window;
            currentAmountInFlight = _amountInFlight > decay
                ? _amountInFlight - decay
                : 0;
            availableCapacity = _limit > currentAmountInFlight
                ? _limit - currentAmountInFlight
                : 0;
            return (currentAmountInFlight, availableCapacity);
        }
    }

    /**
     * @notice Checks current amount in flight and amount that can be sent for a given rate limit window.
     * @param _amountInFlight The amount in the current window.
     * @param _lastUpdated Timestamp representing the last time the rate limit was checked or updated.
     * @param _limit This represents the maximum allowed amount within a given window.
     * @param _window Defines the duration of the rate limiting window.
     * @return currentAmountInFlight The amount in the current window.
     * @return amountCanBeSent The amount that can be sent.
     */
    function _amountCanBeSent(
        uint256 _amountInFlight,
        uint256 _lastUpdated,
        uint256 _limit,
        uint256 _window
    )
        internal
        view
        virtual
        returns (uint256 currentAmountInFlight, uint256 amountCanBeSent)
    {
        (currentAmountInFlight, amountCanBeSent) = _calculateDecay(
            _amountInFlight,
            _lastUpdated,
            _limit,
            _window
        );
    }

    /**
     * @notice Checks current amount in flight and amount that can be sent for a given rate limit window.
     * @param _amountInFlight The amount in the current window.
     * @param _lastUpdated Timestamp representing the last time the rate limit was checked or updated.
     * @param _limit This represents the maximum allowed amount within a given window.
     * @param _window Defines the duration of the rate limiting window.
     * @return currentAmountInFlight The amount in the current window.
     * @return amountCanBeReceived The amount that can be received.
     */
    function _amountCanBeReceived(
        uint256 _amountInFlight,
        uint256 _lastUpdated,
        uint256 _limit,
        uint256 _window
    )
        internal
        view
        virtual
        returns (uint256 currentAmountInFlight, uint256 amountCanBeReceived)
    {
        (currentAmountInFlight, amountCanBeReceived) = _calculateDecay(
            _amountInFlight,
            _lastUpdated,
            _limit,
            _window
        );
    }

    /**
     * @notice Checks and updates the rate limit based on the endpoint ID and amount.
     * @param _eid The endpoint ID for which the rate limit needs to be checked and updated.
     * @param _amount The amount to add to the current amount in flight.
     * @param direction The direction (Outbound or Inbound) of the rate limits being checked.
     */
    function _checkAndUpdateRateLimit(
        uint32 _eid,
        uint256 _amount,
        RateLimitDirection direction
    ) internal {
        // Select the correct mapping based on the direction of the rate limit
        RateLimit storage rl = direction == RateLimitDirection.Outbound
            ? outboundRateLimits[_eid]
            : inboundRateLimits[_eid];

        // Calculate current amount in flight and available capacity
        (
            uint256 currentAmountInFlight,
            uint256 availableCapacity
        ) = _calculateDecay(
                rl.amountInFlight,
                rl.lastUpdated,
                rl.limit,
                rl.window
            );

        // Check if the requested amount exceeds the available capacity
        if (_amount > availableCapacity) {
            revert RateLimitExceeded();
        }

        // Update the rate limit with the new amount in flight and the current timestamp
        rl.amountInFlight = currentAmountInFlight + _amount;
        rl.lastUpdated = block.timestamp;

        RateLimit storage oppositeRL = direction == RateLimitDirection.Outbound
            ? inboundRateLimits[_eid]
            : outboundRateLimits[_eid];
        (
            uint256 otherCurrentAmountInFlight,
            uint256 otherAvailableCapacity
        ) = _calculateDecay(
                oppositeRL.amountInFlight,
                oppositeRL.lastUpdated,
                oppositeRL.limit,
                oppositeRL.window
            );
        unchecked {
            oppositeRL.amountInFlight = otherCurrentAmountInFlight > _amount
                ? otherCurrentAmountInFlight - _amount
                : 0;
        }
        oppositeRL.lastUpdated = block.timestamp;
    }
}
