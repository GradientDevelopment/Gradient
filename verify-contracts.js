const hre = require("hardhat");
const { ROUTER_ADDRESSES } = require("./config/addresses");

// Deployed addresses on mainnet
const DEPLOYED_ADDRESSES = {
    "GradientRegistry": "0xdB7E3b94bd55FB9D93112830b23BAE82E33527c9",
    "UniswapV3PriceHelper": "0x790521294b8F9058a3C69763c99333D309d7FF90",
    "FallbackExecutor": "0x8b9cDD5c9e8292922F514AbE50B84922A033c867",
    "GradientFeeManager": "0x6A3D8c4d5Cb61cC6764Fa54378467bfAe225fC7F",
    "GradientMarketMakerFactory": "0x1B437eec9652e29BbD2B89a2F2d9B47Ea4Ea2B2F",
    "GradientOrderbook": "0x605B99397c54556d97F6f807706b1ecC3c802B15",
    "EventAggregator": "0xE189c082F9A0239f728fe4351558E1ffDE0DD1da",
};

async function main() {
    console.log("Starting contract verification on Etherscan...\n");

    // 1. GradientRegistry - no constructor args
    console.log("Verifying GradientRegistry...");
    try {
        await hre.run("verify:verify", {
            address: DEPLOYED_ADDRESSES.GradientRegistry,
            constructorArguments: [],
        });
        console.log("✓ GradientRegistry verified\n");
    } catch (error) {
        console.log("✗ GradientRegistry verification failed:", error.message, "\n");
    }

    // 2. GradientMarketMakerFactory - [gradientRegistry, eventAggregator placeholder]
    console.log("Verifying GradientMarketMakerFactory...");
    try {
        await hre.run("verify:verify", {
            address: DEPLOYED_ADDRESSES.GradientMarketMakerFactory,
            constructorArguments: [
                DEPLOYED_ADDRESSES.GradientRegistry,
                "0x0000000000000000000000000000000000000000", // Placeholder
            ],
        });
        console.log("✓ GradientMarketMakerFactory verified\n");
    } catch (error) {
        console.log(
            "✗ GradientMarketMakerFactory verification failed:",
            error.message,
            "\n"
        );
    }

    // 3. EventAggregator - [gradientMarketMakerFactory]
    console.log("Verifying EventAggregator...");
    try {
        await hre.run("verify:verify", {
            address: DEPLOYED_ADDRESSES.EventAggregator,
            constructorArguments: [DEPLOYED_ADDRESSES.GradientMarketMakerFactory],
        });
        console.log("✓ EventAggregator verified\n");
    } catch (error) {
        console.log("✗ EventAggregator verification failed:", error.message, "\n");
    }

    // 4. FallbackExecutor - [gradientRegistry]
    console.log("Verifying FallbackExecutor...");
    try {
        await hre.run("verify:verify", {
            address: DEPLOYED_ADDRESSES.FallbackExecutor,
            constructorArguments: [DEPLOYED_ADDRESSES.GradientRegistry],
        });
        console.log("✓ FallbackExecutor verified\n");
    } catch (error) {
        console.log("✗ FallbackExecutor verification failed:", error.message, "\n");
    }

    // 5. GradientFeeManager - [gradientRegistry]
    console.log("Verifying GradientFeeManager...");
    try {
        await hre.run("verify:verify", {
            address: DEPLOYED_ADDRESSES.GradientFeeManager,
            constructorArguments: [DEPLOYED_ADDRESSES.GradientRegistry],
        });
        console.log("✓ GradientFeeManager verified\n");
    } catch (error) {
        console.log("✗ GradientFeeManager verification failed:", error.message, "\n");
    }

    // 6. UniswapV3PriceHelper - [uniswapV3Factory]
    console.log("Verifying UniswapV3PriceHelper...");
    try {
        await hre.run("verify:verify", {
            address: DEPLOYED_ADDRESSES.UniswapV3PriceHelper,
            constructorArguments: [ROUTER_ADDRESSES.mainnet.uniswapV3Factory],
        });
        console.log("✓ UniswapV3PriceHelper verified\n");
    } catch (error) {
        console.log(
            "✗ UniswapV3PriceHelper verification failed:",
            error.message,
            "\n"
        );
    }

    // 7. GradientOrderbook - [gradientRegistry]
    console.log("Verifying GradientOrderbook...");
    try {
        await hre.run("verify:verify", {
            address: DEPLOYED_ADDRESSES.GradientOrderbook,
            constructorArguments: [DEPLOYED_ADDRESSES.GradientRegistry],
        });
        console.log("✓ GradientOrderbook verified\n");
    } catch (error) {
        console.log("✗ GradientOrderbook verification failed:", error.message, "\n");
    }

    console.log("\nVerification process completed!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

