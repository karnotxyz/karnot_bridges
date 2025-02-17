import * as dotenv from "dotenv";
dotenv.config();

import { deployContract, getAccount, declareContract, getContracts, getProvider } from "./utils";
import { Account, ByteArray, RawArgs, uint256, RpcProvider, TransactionExecutionStatus, extractContractHashes, hash, json, provider, byteArray, Contract, num } from 'starknet'

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

const messagingContract = '0x123456';

async function deployAppchainBridge(acc: Account) {
    const { class_hash } = await declareContract("TokenBridge", "starkgate_contracts", "./starkgate-contracts/cairo_contracts");
    sleep(10000);
    const contract = await deployContract("AppchainBridge", class_hash, [process.env.ACCOUNT_ADDRESS as string, "86400"]);
    console.log("AppchainBridge deployed at: ", contract.address);
}

async function deployL2Brdige(acc: Account) {
    const { class_hash } = await declareContract("TokenBridge", "starknet_bridge");
    sleep(10000);
    const appchainBridge = getContracts().AppchainBridge;
    const contract = await deployContract("TokenBridge", class_hash, [
        appchainBridge,
        messagingContract,
        process.env.ACCOUNT_ADDRESS as string
    ]);
    console.log("TokenBridge L2 deployed at: ", contract.address);
}



async function main() {
    const acc = getAccount();

    // Deploy Appchain bridge
    await deployAppchainBridge(acc);

    // await deployL2Brdige(acc);
}

main();