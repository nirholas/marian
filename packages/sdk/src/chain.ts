import { defineChain } from 'viem';

/**
 * Robinhood Chain, where the tokenized equities this protocol is written against actually live.
 *
 * The RPC list is ordered by what was measured to work rather than by what is advertised: the
 * official endpoint prunes state aggressively and `robinhood.drpc.org` does not implement several
 * standard methods, so neither is a safe default for a client that reads history.
 */
export const robinhoodChain = defineChain({
  id: 4663,
  name: 'Robinhood Chain',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: {
    default: {
      http: [
        'https://rpc-robinhood.blockmachine.io',
        'https://robinhood.api.pocket.network',
        'https://robinhood-rpc.publicnode.com',
      ],
    },
  },
  blockExplorers: { default: { name: 'Blockscout', url: 'https://robinhoodchain.blockscout.com' } },
});

export const robinhoodTestnet = defineChain({
  id: 46630,
  name: 'Robinhood Chain Testnet',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.testnet.chain.robinhood.com'] } },
  blockExplorers: {
    default: { name: 'Blockscout', url: 'https://robinhoodchain-testnet.blockscout.com' },
  },
});

/** USDG, the dollar every product here is denominated in. Six decimals, Permit2 only. */
export const USDG = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168' as const;

/** The single `Stock` implementation every tokenized equity proxies onto. */
export const STOCK_IMPLEMENTATION = '0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2' as const;

/** Uniswap v3 on this chain, used for pricing and for turning settled shares back into dollars. */
export const UNISWAP_V3_FACTORY = '0x1f7d7550B1b028f7571E69A784071F0205FD2EfA' as const;
export const SWAP_ROUTER_02 = '0xCaf681a66D020601342297493863E78C959E5cb2' as const;
