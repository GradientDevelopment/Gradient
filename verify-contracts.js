const hre = require("hardhat");
const { ROUTER_ADDRESSES } = require("./config/addresses");

// Deployed addresses on mainnet
const DEPLOYED_ADDRESSES = {
    GradientRegistry: "0x0486C945499FE312a57e54E2C3606B963cAAe244",
    UniswapV3PriceHelper: "0xd9F15B3b04c5bCa761CfFbD97e2ef411A7c775E8",
    FallbackExecutor: "0x207FC29CCCE39f934b97eFcf5DaAAB563642573f",
    GradientFeeManager: "0xcD72c0539D8bF7EB321d3Fcc5FB1a3c288B7FC0a",
    GradientMarketMakerFactory: "0x9c04f49A472D8592030f4088551C51b06bbC7b05",
    GradientOrderbook: "0x2d036AFA7Df77Ba8375E1A544a6315A8fC89E9dE",
    EventAggregator: "0x1189E32b4c602B516Ed1d6C5bBbA607C25966B1D",
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

