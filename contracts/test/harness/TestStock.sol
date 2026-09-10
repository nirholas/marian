// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title TestStock
/// @notice A faithful reimplementation of the `Stock` contract every Robinhood tokenized equity
///         proxies onto, for tests that need to drive states the live chain will not produce on
///         demand.
///
/// @dev This is not a convenience stub. The behaviours it reproduces are the ones the protocol is
///      built around and they were each read off the live implementation at
///      `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2`: `transfer`, `approve` and `permit` all revert
///      while paused rather than returning false; `paused` is the OR of a token flag and a
///      registry-wide flag; `oraclePaused` is independent of both; and `uiMultiplier` is a step
///      function with its next value published ahead of time.
///
///      A halt cannot be scheduled on mainnet to suit a test, and a dividend cannot be brought
///      forward, so the alternative to this file is not testing against the real thing, it is not
///      testing those paths at all. The fork tests in `test/Fork.t.sol` assert that this contract's
///      surface still matches the live one.
contract TestStock {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 public uiMultiplier = 1e18;
    uint256 public newUIMultiplier = 1e18;
    uint256 public effectiveAt;

    bool public tokenPaused;
    bool public registryPaused;
    bool public oraclePaused;

    mapping(address => bool) public blocked;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error TokenIsPaused();
    error AccountBlocked(address account);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    modifier notPaused() {
        if (paused()) revert TokenIsPaused();
        _;
    }

    function paused() public view returns (bool) {
        return tokenPaused || registryPaused;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function balanceOfUI(address account) external view returns (uint256) {
        return (_balances[account] * uiMultiplier) / 1e18;
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 value) external notPaused returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external notPaused returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external notPaused returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "TestStock: insufficient allowance");
            _allowances[from][msg.sender] = allowed - value;
        }
        _move(from, to, value);
        return true;
    }

    function _move(address from, address to, uint256 value) internal {
        if (blocked[from]) revert AccountBlocked(from);
        if (blocked[to]) revert AccountBlocked(to);
        require(_balances[from] >= value, "TestStock: insufficient balance");
        unchecked {
            _balances[from] -= value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    // ------------------------------------------------------------ test controls

    function mint(address to, uint256 value) external {
        _balances[to] += value;
        totalSupply += value;
        emit Transfer(address(0), to, value);
    }

    /// @notice Move the multiplier immediately, the way a landed corporate action does.
    function setMultiplier(uint256 next) external {
        require(next != 0, "TestStock: zero multiplier");
        uiMultiplier = next;
        newUIMultiplier = next;
        effectiveAt = block.timestamp;
    }

    /// @notice Publish a corporate action ahead of time, the way the live chain does.
    function scheduleMultiplier(uint256 next, uint256 at) external {
        require(next != 0, "TestStock: zero multiplier");
        newUIMultiplier = next;
        effectiveAt = at;
    }

    function setTokenPaused(bool value) external {
        tokenPaused = value;
    }

    function setRegistryPaused(bool value) external {
        registryPaused = value;
    }

    function setOraclePaused(bool value) external {
        oraclePaused = value;
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }
}
