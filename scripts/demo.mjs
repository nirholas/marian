#!/usr/bin/env node
/**
 * Bring the whole protocol up locally, against a fork of Robinhood Chain.
 *
 *   node scripts/demo.mjs            # boot, deploy, configure, seed, and leave it running
 *   node scripts/demo.mjs --check    # the same, then assert every surface answers, then exit
 *
 * The fork is the point. Every equity, every pool, every multiplier and every halt flag is the real
 * one, read from the real chain, so the deployment this produces is configured against the same
 * facts a mainnet deployment would be. The only thing that is local is the block production and the
 * dollars, which are conjured by writing USDG's balance slot directly.
 */
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { encodeAbiParameters, keccak256, toHex, pad } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const CHECK = process.argv.includes('--check');
const PORT = Number(process.env.DEMO_PORT ?? 8599);
const RPC = `http://127.0.0.1:${PORT}`;
const FORK_URL = process.env.RHC_RPC_URL ?? 'https://rpc-robinhood.blockmachine.io';

const USDG = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168';
const SWAP_ROUTER_02 = '0xCaf681a66D020601342297493863E78C959E5cb2';
/** USDG keeps balances in mapping slot 1. Verified by writing a slot and reading `balanceOf` back. */
const USDG_BALANCE_SLOT = 1n;

const foundryBin = process.env.FOUNDRY_BIN ?? `${process.env.HOME}/.foundry/bin`;
const bin = (name) => join(foundryBin, name);

const log = (...args) => console.log('[demo]', ...args);

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed:\n${result.stdout ?? ''}${result.stderr ?? ''}`);
  }
  return result.stdout ?? '';
}

async function rpcCall(method, params) {
  const response = await fetch(RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const json = await response.json();
  if (json.error) throw new Error(`${method}: ${json.error.message}`);
  return json.result;
}

async function waitForNode(timeoutMs = 60_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      await rpcCall('eth_chainId', []);
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 400));
    }
  }
  throw new Error('anvil did not come up');
}

/** Give an address USDG by writing the balance slot, the only way to get dollars on a fork. */
async function mintUsdg(to, amount) {
  const slot = keccak256(
    encodeAbiParameters(
      [{ type: 'address' }, { type: 'uint256' }],
      [to, USDG_BALANCE_SLOT],
    ),
  );
  await rpcCall('anvil_setStorageAt', [USDG, slot, pad(toHex(amount), { size: 32 })]);
}

const anvil = spawn(
  bin('anvil'),
  [
    '--fork-url', FORK_URL,
    '--port', String(PORT),
    '--silent',
    '--compute-units-per-second', '120',
    '--fork-retry-backoff', '2',
    '--retries', '6',
  ],
  { stdio: ['ignore', 'ignore', 'inherit'] },
);
let shuttingDown = false;
const shutdown = (code) => {
  if (shuttingDown) return;
  shuttingDown = true;
  anvil.kill('SIGTERM');
  process.exit(code);
};
process.on('SIGINT', () => shutdown(130));
process.on('SIGTERM', () => shutdown(143));

try {
  log(`forking ${FORK_URL} on :${PORT}`);
  await waitForNode();

  // Fresh key. The well-known anvil accounts are EIP-7702 delegated on this chain, which makes
  // anything that inspects code at the sender behave differently from a plain EOA.
  const deployerKey = '0x' + '11'.repeat(32);
  const deployer = privateKeyToAccount(deployerKey);
  await rpcCall('anvil_setBalance', [deployer.address, toHex(10n ** 20n)]);
  log(`deployer ${deployer.address}`);

  const env = {
    ...process.env,
    USDG_ADDRESS: USDG,
    SWAP_ROUTER_02,
    MARIAN_OWNER: deployer.address,
    FEE_SINK: deployer.address,
  };
  log('deploying');
  const output = run(
    bin('forge'),
    [
      'script', 'script/Deploy.s.sol:Deploy',
      '--root', join(root, 'contracts'),
      '--rpc-url', RPC,
      '--private-key', deployerKey,
      '--broadcast',
      '--skip-simulation',
      '-vvv',
    ],
    { env, cwd: join(root, 'contracts') },
  );

  const addresses = {};
  for (const [key, label] of [
    ['registry', 'registry'], ['oracle', 'oracle'], ['volSurface', 'volSurface'],
    ['paidOrders', 'paidOrders'], ['underwriterVault', 'underwriterVault'], ['swapVenue', 'swapVenue'],
    ['creditLine', 'creditLine'], ['termRepo', 'termRepo'], ['accrualStrip', 'accrualStrip'],
  ]) {
    const match = output.match(new RegExp(`${label}\\s*(0x[0-9a-fA-F]{40})`));
    if (!match) throw new Error(`deploy output did not report ${label}`);
    addresses[key] = match[1];
  }
  log('deployed', addresses.paidOrders);

  const { assets } = JSON.parse(readFileSync(join(root, 'data', 'assets.json'), 'utf8'));
  // Configure the deepest names only. Every one of these was verified against the chain by
  // scripts/refresh-assets.mjs; the tail is left out because a venue with a bid nobody can hedge
  // is worse than no venue on that ticker.
  const listed = assets.filter((a) => !a.paused && !a.oraclePaused).slice(0, 12);

  const send = (to, signature, args) =>
    run(bin('cast'), [
      'send', to, signature, ...args,
      '--rpc-url', RPC, '--private-key', deployerKey, '--json',
    ]);

  log(`configuring ${listed.length} assets`);
  for (const asset of listed) {
    send(addresses.registry, 'configure(address,(bool,uint16,uint16,uint16,uint32,uint32,uint128,uint16))', [
      asset.address,
      `(true,2500,5000,6500,86400,10368000,${5_000_000n * 10n ** 8n},100)`,
    ]);
    send(addresses.oracle, 'configure(address,(address,bool,uint32,uint16,uint32,bool))', [
      asset.address,
      `(${asset.pool},${asset.assetIsToken0},1800,500,3600,true)`,
    ]);
    send(addresses.swapVenue, 'setFeeTier(address,uint24)', [asset.address, String(asset.fee)]);
  }

  log('posting volatility');
  send(addresses.volSurface, 'setReporter(address,bool)', [deployer.address, 'true']);
  for (const asset of listed) {
    // A starting surface, not a forecast: 45% at the money with the ordinary equity skew. A live
    // deployment replaces this with a reporter that measures.
    send(addresses.volSurface, 'post(address,uint256,int256)', [
      asset.address, '450000000000000000', '-600000000000000000',
    ]);
  }

  log('seeding the vault and the lending pool');
  const seed = 5_000_000n * 10n ** 6n;
  await mintUsdg(deployer.address, seed * 4n);
  send(addresses.paidOrders, 'setRate(int256)', ['40000000000000000']);
  send(addresses.underwriterVault, 'setLimits(uint256,uint256,uint256,uint256,uint256)', [
    '2000', '500', String(250_000n * 10n ** 6n), String(2_000_000n * 10n ** 6n), '3000',
  ]);
  send(addresses.underwriterVault, 'setKeeper(address,bool)', [deployer.address, 'true']);
  send(USDG, 'approve(address,uint256)', [addresses.underwriterVault, String(seed)]);
  send(addresses.underwriterVault, 'deposit(uint256)', [String(seed)]);
  send(USDG, 'approve(address,uint256)', [addresses.creditLine, String(seed)]);
  send(addresses.creditLine, 'supply(uint256)', [String(seed)]);
  for (const [term, apr] of [[30 * 86400, 800], [90 * 86400, 950], [180 * 86400, 1050]]) {
    send(addresses.termRepo, 'setTerm(uint32,uint16)', [String(term), String(apr)]);
  }

  const blockNumber = Number(await rpcCall('eth_blockNumber', []));
  // A forking anvil adopts the forked chain's id rather than 31337, so the deployment is filed
  // under whatever the node actually reports. Assuming 31337 files it under an id no client ever
  // sees, and the app then renders "not deployed" against a node it is talking to happily.
  const localChainId = Number(await rpcCall('eth_chainId', []));
  const deployment = { ...addresses, deployedAtBlock: blockNumber };
  writeFileSync(
    join(root, 'packages', 'sdk', 'src', 'addresses.ts'),
    buildAddressesModule({ [localChainId]: deployment }),
  );
  mkdirSync(join(root, 'data'), { recursive: true });
  writeFileSync(
    join(root, 'data', 'demo-deployment.json'),
    JSON.stringify({ rpc: RPC, chainId: localChainId, forkOf: 4663, ...deployment, assets: listed.map((a) => a.symbol) }, null, 2),
  );
  log('wrote packages/sdk/src/addresses.ts and data/demo-deployment.json');

  if (CHECK) {
    log('checking every surface answers');
    const call = (to, signature, args = []) =>
      run(bin('cast'), ['call', to, signature, ...args, '--rpc-url', RPC]).trim();

    const listedCount = BigInt(call(addresses.registry, 'listedCount()(uint256)').split(' ')[0]);
    if (listedCount !== BigInt(listed.length)) throw new Error(`registry lists ${listedCount}`);

    const nav = BigInt(call(addresses.underwriterVault, 'nav()(uint256)').split(' ')[0]);
    if (nav < seed / 2n) throw new Error(`vault nav is ${nav}`);

    const spot = BigInt(call(addresses.paidOrders, 'spotRawOf(address)(uint256)', [listed[0].address]).split(' ')[0]);
    if (spot === 0n) throw new Error('oracle returned no price');
    log(`${listed[0].symbol} spot ${Number(spot) / 1e8}`);

    const expiries = call(addresses.paidOrders, 'upcomingExpiries(uint256)(uint64[])', ['4']);
    if (!expiries.includes(',')) throw new Error('no expiries offered');

    const cash = BigInt(call(addresses.creditLine, 'cash()(uint256)').split(' ')[0]);
    if (cash < seed / 2n) throw new Error(`credit line holds ${cash}`);

    log('all surfaces answered');
    shutdown(0);
  }

  log(`running. RPC ${RPC}. Ctrl-C to stop.`);
  await new Promise(() => {});
} catch (error) {
  console.error('[demo] failed:', error.message);
  shutdown(1);
}

function buildAddressesModule(byChain) {
  const body = Object.entries(byChain)
    .map(([chainId, d]) =>
      `  ${chainId}: {\n` +
      Object.entries(d)
        .map(([k, v]) => `    ${k}: ${typeof v === 'number' ? v : `'${v}'`}${typeof v === 'number' ? '' : ' as \`0x${string}\`'},`)
        .join('\n') +
      '\n  },',
    )
    .join('\n');

  return `/**
 * Deployed addresses, per chain.
 *
 * Generated by scripts/demo.mjs from the deployment it just broadcast. Every address in here was
 * created by a transaction rather than typed by hand.
 */
export type Deployment = {
  registry: \`0x\${string}\`;
  oracle: \`0x\${string}\`;
  volSurface: \`0x\${string}\`;
  paidOrders: \`0x\${string}\`;
  underwriterVault: \`0x\${string}\`;
  swapVenue: \`0x\${string}\`;
  creditLine: \`0x\${string}\`;
  termRepo: \`0x\${string}\`;
  accrualStrip: \`0x\${string}\`;
  deployedAtBlock: number;
};

export const DEPLOYMENTS: Partial<Record<number, Deployment>> = {
${body}
};

export function deploymentFor(chainId: number): Deployment {
  const found = DEPLOYMENTS[chainId];
  if (!found) {
    throw new Error(
      \`Marian is not deployed on chain \${chainId}. Run scripts/demo.mjs, which writes this map.\`,
    );
  }
  return found;
}

export const isDeployed = (chainId: number): boolean => DEPLOYMENTS[chainId] !== undefined;
`;
}
