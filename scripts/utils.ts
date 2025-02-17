import dotenv from 'dotenv';
dotenv.config();
import assert from 'assert'
import { Account, RawArgs, RpcProvider, TransactionFinalityStatus, extractContractHashes, hash, json, provider } from 'starknet'
import { readFileSync, existsSync, writeFileSync } from 'fs'

console.log('===============================')
console.log(`Network: ${process.env.NETWORK}`);
console.log(`RPC: ${process.env.RPC_URL}`);
console.log('===============================')


export function getContracts() {
  const PATH = './contracts.json'
  if (existsSync(PATH)) {
    return JSON.parse(readFileSync(PATH, { encoding: 'utf-8' }))
  }
  return {}
}

function saveContracts(contracts: any) {
  const PATH = './contracts.json'
  writeFileSync(PATH, JSON.stringify(contracts));
}

export function getProvider(): RpcProvider {
  assert(process.env.RPC_URL, 'invalid RPC_URL');
  return new RpcProvider({ nodeUrl: process.env.RPC_URL as string, retries: 5 });
}

export function getAccount(): Account {
  // initialize provider
  const provider = getProvider();
  const privateKey = process.env.ACCOUNT_PRIVATE_KEY as string;
  const accountAddress: string = process.env.ACCOUNT_ADDRESS as string;
  return new Account(provider, accountAddress, privateKey);
}

export async function declareContract(contract_name: string, package_name: string, base_path: string = './target/dev') {
  const provider = getProvider();
  const acc = getAccount();
  const compiledSierra = json.parse(
    readFileSync(`${base_path}/${package_name}_${contract_name}.contract_class.json`).toString("ascii")
  )
  const compiledCasm = json.parse(
    readFileSync(`${base_path}/${package_name}_${contract_name}.compiled_contract_class.json`).toString("ascii")
  )

  const contracts = getContracts();
  const payload = {
    contract: compiledSierra,
    casm: compiledCasm
  };

  const fee = await acc.estimateDeclareFee({
    contract: compiledSierra,
    casm: compiledCasm,
  })
  console.log('declare fee', Number(fee.suggestedMaxFee) / 10 ** 18, 'ETH')
  const result = extractContractHashes(payload);
  console.log("classhash:", result.classHash);

  const tx = await acc.declareIfNot(payload)

  await provider.waitForTransaction(tx.transaction_hash, {
    successStates: [TransactionFinalityStatus.ACCEPTED_ON_L2]
  })

  console.log(`Declaring: ${contract_name}, tx:`, tx.transaction_hash);
  if (!contracts.class_hashes) {
    contracts['class_hashes'] = {};
  }
  // Todo attach cairo and scarb version. and commit ID
  contracts.class_hashes[contract_name] = tx.class_hash;
  saveContracts(contracts);
  console.log(`Contract declared: ${contract_name}`)
  console.log(`Class hash: ${tx.class_hash}`)

  return tx;
}

export async function deployContract(contract_name: string, classHash: string, constructorData: RawArgs) {
  const provider = getProvider();
  const acc = getAccount();

  const fee = await acc.estimateDeployFee({
    classHash,
    constructorCalldata: constructorData,
  })
  console.log("Deploy fee", contract_name, Number(fee.suggestedMaxFee) / 10 ** 18, 'ETH')

  const tx = await acc.deployContract({
    classHash,
    constructorCalldata: constructorData,
  })
  console.log('Deploy tx: ', tx.transaction_hash);

  await provider.waitForTransaction(tx.transaction_hash, {
    // successStates: [TransactionFinalityStatus.ACCEPTED_ON_L2],
    retryInterval: 100,
  })

  const contracts = getContracts();
  if (!contracts.contracts) {
    contracts['contracts'] = {};
  }
  contracts.contracts[contract_name] = tx.contract_address;
  saveContracts(contracts);
  console.log(`Contract deployed: ${contract_name}`)
  console.log(`Address: ${tx.contract_address}`);

  return tx;
}
