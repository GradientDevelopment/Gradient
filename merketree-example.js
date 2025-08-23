const { ethers } = require('ethers');

// =============================== SIMPLE FUNCTIONS ===============================

/**
 * Create merkle root from user positions
 */
function createMerkleRoot(userPositions) {
    const leaves = [];
    const addressToIndex = new Map();

    // Create leaves
    for (const [address, position] of userPositions) {
        const leaf = ethers.utils.keccak256(
            ethers.utils.solidityPack(
                ['address', 'uint256', 'uint256'],
                [address, position.ethPosition, position.tokenPosition]
            )
        );
        
        leaves.push(leaf);
        addressToIndex.set(address, leaves.length - 1);
    }

    // Build tree and get root
    const merkleTree = buildMerkleTree(leaves);
    const merkleRoot = merkleTree[merkleTree.length - 1][0];

    // Generate proofs
    const proofs = new Map();
    for (const [address, index] of addressToIndex) {
        proofs.set(address, getMerkleProof(leaves, index));
    }

    return { merkleRoot, proofs };
}

/**
 * Build merkle tree
 */
function buildMerkleTree(leaves) {
    if (leaves.length === 0) return [];
    if (leaves.length === 1) return [leaves];

    const tree = [leaves];
    let currentLevel = leaves;

    while (currentLevel.length > 1) {
        const nextLevel = [];
        
        for (let i = 0; i < currentLevel.length; i += 2) {
            if (i + 1 < currentLevel.length) {
                const hash = ethers.utils.keccak256(
                    ethers.utils.solidityPack(
                        ['bytes32', 'bytes32'],
                        [currentLevel[i], currentLevel[i + 1]]
                    )
                );
                nextLevel.push(hash);
            } else {
                // Duplicate last node
                const hash = ethers.utils.keccak256(
                    ethers.utils.solidityPack(
                        ['bytes32', 'bytes32'],
                        [currentLevel[i], currentLevel[i]]
                    )
                );
                nextLevel.push(hash);
            }
        }
        
        tree.push(nextLevel);
        currentLevel = nextLevel;
    }

    return tree;
}

/**
 * Get merkle proof
 */
function getMerkleProof(leaves, leafIndex) {
    const proof = [];
    let currentIndex = leafIndex;
    let currentLevel = leaves;

    while (currentLevel.length > 1) {
        const nextLevel = [];
        const isRightNode = currentIndex % 2 === 1;
        const siblingIndex = isRightNode ? currentIndex - 1 : currentIndex + 1;

        if (siblingIndex < currentLevel.length) {
            proof.push(currentLevel[siblingIndex]);
        }

        // Build next level
        for (let i = 0; i < currentLevel.length; i += 2) {
            if (i + 1 < currentLevel.length) {
                const hash = ethers.utils.keccak256(
                    ethers.utils.solidityPack(
                        ['bytes32', 'bytes32'],
                        [currentLevel[i], currentLevel[i + 1]]
                    )
                );
                nextLevel.push(hash);
            } else {
                const hash = ethers.utils.keccak256(
                    ethers.utils.solidityPack(
                        ['bytes32', 'bytes32'],
                        [currentLevel[i], currentLevel[i]]
                    )
                );
                nextLevel.push(hash);
            }
        }

        currentLevel = nextLevel;
        currentIndex = Math.floor(currentIndex / 2);
    }

    return proof;
}

/**
 * Verify merkle proof
 */
function verifyMerkleProof(leaf, proof, root) {
    let computedHash = leaf;

    for (const proofElement of proof) {
        if (ethers.BigNumber.from(computedHash).lt(ethers.BigNumber.from(proofElement))) {
            computedHash = ethers.utils.keccak256(
                ethers.utils.solidityPack(
                    ['bytes32', 'bytes32'],
                    [computedHash, proofElement]
                )
            );
        } else {
            computedHash = ethers.utils.keccak256(
                ethers.utils.solidityPack(
                    ['bytes32', 'bytes32'],
                    [proofElement, computedHash]
                )
            );
        }
    }

    return computedHash === root;
}

// =============================== USAGE ===============================

// Simple data structure
const userPositions = new Map();

// Add users
userPositions.set('0x1234567890123456789012345678901234567890', {
    ethPosition: '1000000000000000000',    // 1 ETH
    tokenPosition: '500000000000000000000'  // 500 tokens
});

userPositions.set('0x2345678901234567890123456789012345678901', {
    ethPosition: '2000000000000000000',    // 2 ETH
    tokenPosition: '0'                     // No tokens
});

userPositions.set('0x3456789012345678901234567890123456789012', {
    ethPosition: '0',                      // No ETH
    tokenPosition: '1000000000000000000000' // 1000 tokens
});

// Create merkle root
const { merkleRoot, proofs } = createMerkleRoot(userPositions);

console.log('=== SIMPLE MERKLE TREE ===');
console.log('Merkle Root:', merkleRoot);
console.log('Total Users:', userPositions.size);

// Get proof for user
const userAddress = '0x1234567890123456789012345678901234567890';
const proof = proofs.get(userAddress);

console.log('\nProof for user:', userAddress);
console.log('Proof:', proof);

// Verify proof
const userPosition = userPositions.get(userAddress);
const leaf = ethers.utils.keccak256(
    ethers.utils.solidityPack(
        ['address', 'uint256', 'uint256'],
        [userAddress, userPosition.ethPosition, userPosition.tokenPosition]
    )
);

const isValid = verifyMerkleProof(leaf, proof, merkleRoot);
console.log('\nProof Valid:', isValid);