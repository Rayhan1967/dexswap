// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract SimpleDEX {
    address public owner;
    uint256 public feePercentage = 3; // 0.3% fee (3/1000)
    
    // Liquidity Pool Structure
    struct Pool {
        address tokenA;
        address tokenB;
        uint256 reserveA;
        uint256 reserveB;
        uint256 totalLiquidity;
        bool exists;
    }
    
    // Mapping untuk pools: keccak256(tokenA, tokenB) => Pool
    mapping(bytes32 => Pool) public pools;
    
    // Mapping untuk liquidity provider shares: poolId => user => shares
    mapping(bytes32 => mapping(address => uint256)) public liquidityShares;
    
    // Array untuk track semua pool IDs
    bytes32[] public poolIds;
    
    // Events
    event PoolCreated(address indexed tokenA, address indexed tokenB, bytes32 poolId);
    event LiquidityAdded(address indexed provider, bytes32 poolId, uint256 amountA, uint256 amountB, uint256 liquidity);
    event LiquidityRemoved(address indexed provider, bytes32 poolId, uint256 amountA, uint256 amountB, uint256 liquidity);
    event TokenSwapped(address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    
    constructor() {
        owner = msg.sender;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }
    
    // Generate pool ID from two token addresses
    function getPoolId(address tokenA, address tokenB) public pure returns (bytes32) {
        // Sort addresses to ensure consistent pool ID
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        return keccak256(abi.encodePacked(tokenA, tokenB));
    }
    
    // Create new liquidity pool
    function createPool(address tokenA, address tokenB) external returns (bytes32) {
        require(tokenA != tokenB, "Identical tokens");
        require(tokenA != address(0) && tokenB != address(0), "Zero address");
        
        bytes32 poolId = getPoolId(tokenA, tokenB);
        require(!pools[poolId].exists, "Pool already exists");
        
        // Sort tokens for consistent storage
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        
        pools[poolId] = Pool({
            tokenA: tokenA,
            tokenB: tokenB,
            reserveA: 0,
            reserveB: 0,
            totalLiquidity: 0,
            exists: true
        });
        
        poolIds.push(poolId);
        emit PoolCreated(tokenA, tokenB, poolId);
        
        return poolId;
    }
    
    // Add liquidity to pool
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        
        bytes32 poolId = getPoolId(tokenA, tokenB);
        require(pools[poolId].exists, "Pool does not exist");
        
        Pool storage pool = pools[poolId];
        
        // Calculate optimal amounts
        if (pool.reserveA == 0 && pool.reserveB == 0) {
            // First liquidity provider
            amountA = amountADesired;
            amountB = amountBDesired;
        } else {
            // Calculate amounts based on current ratio
            uint256 amountBOptimal = (amountADesired * pool.reserveB) / pool.reserveA;
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "Insufficient B amount");
                amountA = amountADesired;
                amountB = amountBOptimal;
            } else {
                uint256 amountAOptimal = (amountBDesired * pool.reserveA) / pool.reserveB;
                require(amountAOptimal <= amountADesired && amountAOptimal >= amountAMin, "Insufficient A amount");
                amountA = amountAOptimal;
                amountB = amountBDesired;
            }
        }
        
        // Calculate liquidity tokens to mint
        if (pool.totalLiquidity == 0) {
            liquidity = sqrt(amountA * amountB);
        } else {
            liquidity = min(
                (amountA * pool.totalLiquidity) / pool.reserveA,
                (amountB * pool.totalLiquidity) / pool.reserveB
            );
        }
        
        require(liquidity > 0, "Insufficient liquidity minted");
        
        // Transfer tokens from user
        require(IERC20(pool.tokenA).transferFrom(msg.sender, address(this), amountA), "Transfer A failed");
        require(IERC20(pool.tokenB).transferFrom(msg.sender, address(this), amountB), "Transfer B failed");
        
        // Update pool reserves and user shares
        pool.reserveA += amountA;
        pool.reserveB += amountB;
        pool.totalLiquidity += liquidity;
        liquidityShares[poolId][msg.sender] += liquidity;
        
        emit LiquidityAdded(msg.sender, poolId, amountA, amountB, liquidity);
    }
    
    // Remove liquidity from pool
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin
    ) external returns (uint256 amountA, uint256 amountB) {
        
        bytes32 poolId = getPoolId(tokenA, tokenB);
        require(pools[poolId].exists, "Pool does not exist");
        require(liquidityShares[poolId][msg.sender] >= liquidity, "Insufficient shares");
        
        Pool storage pool = pools[poolId];
        
        // Calculate amounts to return
        amountA = (liquidity * pool.reserveA) / pool.totalLiquidity;
        amountB = (liquidity * pool.reserveB) / pool.totalLiquidity;
        
        require(amountA >= amountAMin && amountB >= amountBMin, "Insufficient output amounts");
        
        // Update pool reserves and user shares
        pool.reserveA -= amountA;
        pool.reserveB -= amountB;
        pool.totalLiquidity -= liquidity;
        liquidityShares[poolId][msg.sender] -= liquidity;
        
        // Transfer tokens back to user
        require(IERC20(pool.tokenA).transfer(msg.sender, amountA), "Transfer A failed");
        require(IERC20(pool.tokenB).transfer(msg.sender, amountB), "Transfer B failed");
        
        emit LiquidityRemoved(msg.sender, poolId, amountA, amountB, liquidity);
    }
    
    // Swap exact tokens for tokens
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn,
        address tokenOut
    ) external returns (uint256 amountOut) {
        
        bytes32 poolId = getPoolId(tokenIn, tokenOut);
        require(pools[poolId].exists, "Pool does not exist");
        
        Pool storage pool = pools[poolId];
        require(pool.reserveA > 0 && pool.reserveB > 0, "Insufficient liquidity");
        
        // Calculate output amount using AMM formula: x * y = k
        bool tokenInIsA = (tokenIn == pool.tokenA);
        uint256 reserveIn = tokenInIsA ? pool.reserveA : pool.reserveB;
        uint256 reserveOut = tokenInIsA ? pool.reserveB : pool.reserveA;
        
        // Apply fee (0.3%)
        uint256 amountInWithFee = amountIn * (1000 - feePercentage);
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
        
        require(amountOut >= amountOutMin, "Insufficient output amount");
        require(amountOut < reserveOut, "Insufficient liquidity");
        
        // Transfer tokens
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "Transfer in failed");
        require(IERC20(tokenOut).transfer(msg.sender, amountOut), "Transfer out failed");
        
        // Update reserves
        if (tokenInIsA) {
            pool.reserveA += amountIn;
            pool.reserveB -= amountOut;
        } else {
            pool.reserveB += amountIn;
            pool.reserveA -= amountOut;
        }
        
        emit TokenSwapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }
    
    // Get amount out for exact amount in
    function getAmountOut(uint256 amountIn, address tokenIn, address tokenOut) 
        external view returns (uint256 amountOut) {
        
        bytes32 poolId = getPoolId(tokenIn, tokenOut);
        require(pools[poolId].exists, "Pool does not exist");
        
        Pool memory pool = pools[poolId];
        require(pool.reserveA > 0 && pool.reserveB > 0, "Insufficient liquidity");
        
        bool tokenInIsA = (tokenIn == pool.tokenA);
        uint256 reserveIn = tokenInIsA ? pool.reserveA : pool.reserveB;
        uint256 reserveOut = tokenInIsA ? pool.reserveB : pool.reserveA;
        
        uint256 amountInWithFee = amountIn * (1000 - feePercentage);
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }
    
    // Get pool info
    function getPoolInfo(address tokenA, address tokenB) 
        external view returns (
            uint256 reserveA,
            uint256 reserveB,
            uint256 totalLiquidity,
            bool exists
        ) {
        bytes32 poolId = getPoolId(tokenA, tokenB);
        Pool memory pool = pools[poolId];
        return (pool.reserveA, pool.reserveB, pool.totalLiquidity, pool.exists);
    }
    
    // Get user liquidity shares
    function getUserShares(address tokenA, address tokenB, address user) 
        external view returns (uint256) {
        bytes32 poolId = getPoolId(tokenA, tokenB);
        return liquidityShares[poolId][user];
    }
    
    // Get all pool IDs
    function getAllPools() external view returns (bytes32[] memory) {
        return poolIds;
    }
    
    // Update fee (only owner)
    function updateFee(uint256 newFeePercentage) external onlyOwner {
        require(newFeePercentage <= 30, "Fee too high"); // Max 3%
        feePercentage = newFeePercentage;
    }
    
    // Emergency withdraw (only owner)
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner, amount);
    }
    
    // Utility functions
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
    
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}