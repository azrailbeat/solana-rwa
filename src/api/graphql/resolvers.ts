import { OmniFlowSDK } from '../../sdk/core/OmniFlowSDK';
import { 
  Asset, 
  MarketplaceListing, 
  StakingPosition,
  LendingPosition,
  BridgeTransfer,
  ChainId,
  AssetType,
  FilterOptions
} from '../../sdk/core/types';
import { PubSub } from 'graphql-subscriptions';

// Type assertion to fix asyncIterator method recognition
const pubsub = new PubSub() as any;

export const resolvers = {
  // Custom scalar resolvers
  DateTime: {
    serialize: (date: Date) => date.toISOString(),
    parseValue: (value: string) => new Date(value),
    parseLiteral: (ast: any) => new Date(ast.value),
  },

  BigInt: {
    serialize: (value: bigint) => value.toString(),
    parseValue: (value: string) => BigInt(value),
    parseLiteral: (ast: any) => BigInt(ast.value),
  },

  // Enum resolvers
  ChainId: {
    ONECHAIN: 'onechain',
    ETHEREUM: 'ethereum',
    POLYGON: 'polygon',
    BSC: 'bsc',
  },

  AssetType: {
    REAL_ESTATE: 'real-estate',
    RENEWABLE_ENERGY: 'renewable-energy',
    CARBON_CREDITS: 'carbon-credits',
    PRECIOUS_METALS: 'precious-metals',
    COMMODITIES: 'commodities',
    BONDS: 'bonds',
    STOCKS: 'stocks',
    INTELLECTUAL_PROPERTY: 'intellectual-property',
    AGRICULTURE: 'agriculture',
    FORESTRY: 'forestry',
    INFRASTRUCTURE: 'infrastructure',
    ART_COLLECTIBLES: 'art-collectibles',
  },

  // Type resolvers with nested field resolution
  Asset: {
    chainId: (asset: Asset) => asset.chainId.toUpperCase(),
    type: (asset: Asset) => asset.type.toUpperCase().replace('-', '_'),
    status: (asset: Asset) => asset.status.toUpperCase(),
  },

  MarketplaceListing: {
    chainId: (listing: MarketplaceListing) => 'ethereum',
    listingType: (listing: MarketplaceListing) => listing.listingType.toUpperCase(),
    status: (listing: MarketplaceListing) => listing.status.toUpperCase(),
    asset: async (listing: MarketplaceListing, _: any, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.assets.getAsset(listing.assetId);
    },
  },

  StakingPosition: {
    status: (position: StakingPosition) => position.status.toUpperCase(),
    asset: async (position: StakingPosition, _: any, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.assets.getAsset(position.assetId);
    },
  },

  LendingPosition: {
    status: (position: LendingPosition) => position.status.toUpperCase(),
    asset: async (position: LendingPosition, _: any, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.assets.getAsset(position.assetId);
    },
  },

  BridgeTransfer: {
    fromChain: (transfer: BridgeTransfer) => transfer.fromChain.toUpperCase(),
    toChain: (transfer: BridgeTransfer) => transfer.toChain.toUpperCase(),
    status: (transfer: BridgeTransfer) => transfer.status.toUpperCase(),
    asset: async (transfer: BridgeTransfer, _: any, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.assets.getAsset(transfer.assetId);
    },
  },

  Query: {
    // Asset queries
    asset: async (_: any, { id }: { id: string }, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.assets.getAsset(id);
    },

    assets: async (_: any, { filter, limit, offset }: { 
      filter?: FilterOptions; 
      limit?: number; 
      offset?: number; 
    }, { sdk }: { sdk: OmniFlowSDK }) => {
      const assets = await sdk.assets.getAssets(filter);
      const start = offset || 0;
      const end = limit ? start + limit : undefined;
      return assets.slice(start, end);
    },

    assetsByType: async (_: any, { type }: { type: AssetType }, { sdk }: { sdk: OmniFlowSDK }) => {
      const normalizedType = type.toLowerCase().replace('_', '-') as AssetType;
      return await sdk.assets.getAssetsByType(normalizedType);
    },

    assetsByOwner: async (_: any, { owner }: { owner: string }, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.assets.getAssetsByOwner(owner);
    },

    assetsByChain: async (_: any, { chainId }: { chainId: ChainId }, { sdk }: { sdk: OmniFlowSDK }) => {
      const normalizedChainId = chainId.toLowerCase() as ChainId;
      return await sdk.assets.getAssetsByChain(normalizedChainId);
    },

    searchAssets: async (_: any, { query }: { query: string }, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.assets.searchAssets(query);
    },

    assetValuation: async (_: any, { id }: { id: string }, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.assets.getAssetValuation(id);
    },

    validateCompliance: async (_: any, { id }: { id: string }, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.assets.validateCompliance(id);
    },

    // Marketplace queries
    listing: async (_: any, { id }: { id: string }, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.marketplace.getListing(id);
    },

    listings: async (_: any, { filter, limit, offset }: { 
      filter?: FilterOptions; 
      limit?: number; 
      offset?: number; 
    }, { sdk }: { sdk: OmniFlowSDK }) => {
      const listings = await sdk.marketplace.getListings(filter);
      const start = offset || 0;
      const end = limit ? start + limit : undefined;
      return listings.slice(start, end);
    },

    trendingListings: async (_: any, { limit }: { limit?: number }, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.marketplace.getTrendingListings(limit);
    },

    recentSales: async (_: any, { limit }: { limit?: number }, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.marketplace.getRecentSales(limit);
    },

    searchListings: async (_: any, { query }: { query: string }, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.marketplace.searchListings(query);
    },

    marketplaceStats: async (_: any, __: any, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.marketplace.getMarketplaceStats();
    },

    // DeFi queries
    defiPosition: async (_: any, { id }: { id: string }, { sdk }: { sdk: OmniFlowSDK }) => {
      const positions = await sdk.defi.getPositions();
      return positions.find(p => p.id === id) || null;
    },

    defiPositions: async (_: any, { userAddress, limit, offset }: { 
      userAddress?: string; 
      limit?: number; 
      offset?: number; 
    }, { sdk }: { sdk: OmniFlowSDK }) => {
      const positions = await sdk.defi.getPositions(userAddress);
      const start = offset || 0;
      const end = limit ? start + limit : undefined;
      return positions.slice(start, end);
    },

    stakingPools: async (_: any, __: any, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.defi.getStakingPools();
    },

    yieldStrategies: async (_: any, __: any, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.defi.getYieldStrategies();
    },

    defiAnalytics: async (_: any, __: any, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.defi.getDeFiAnalytics();
    },

    // Bridge queries
    bridgeTransfer: async (_: any, { id }: { id: string }, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.bridge.getBridgeTransfer(id);
    },

    bridgeTransfers: async (_: any, { userAddress, limit, offset }: { 
      userAddress?: string; 
      limit?: number; 
      offset?: number; 
    }, { sdk }: { sdk: OmniFlowSDK }) => {
      const transfers = await sdk.bridge.getBridgeTransfers(userAddress);
      const start = offset || 0;
      const end = limit ? start + limit : undefined;
      return transfers.slice(start, end);
    },

    supportedRoutes: async (_: any, __: any, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.bridge.getSupportedRoutes();
    },

    bridgeAnalytics: async (_: any, __: any, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.bridge.getBridgeAnalytics();
    },
  },

  Mutation: {
    // Asset mutations
    createAsset: async (_: any, { input }: { input: any }, { sdk }: { sdk: OmniFlowSDK }) => {
      const createRequest = {
        ...input,
        chainId: input.chainId.toLowerCase(),
        type: input.type.toLowerCase().replace('_', '-'),
      };
      
      const asset = await sdk.assets.createAsset(createRequest);
      
      // Publish subscription event
      pubsub.publish('ASSET_CREATED', { assetCreated: asset });
      
      return asset;
    },

    transferAsset: async (_: any, { id, toAddress }: { id: string; toAddress: string }, { sdk }: { sdk: OmniFlowSDK }) => {
      const transaction = await sdk.assets.transferAsset(id, toAddress);
      
      // Get updated asset and publish subscription event
      const asset = await sdk.assets.getAsset(id);
      if (asset) {
        pubsub.publish('ASSET_TRANSFERRED', { assetTransferred: asset });
      }
      
      return transaction;
    },

    enableFractionalOwnership: async (_: any, { id, totalShares, pricePerShare }: { 
      id: string; 
      totalShares: number; 
      pricePerShare: string; 
    }, { sdk }: { sdk: OmniFlowSDK }) => {
      const asset = await sdk.assets.enableFractionalOwnership(id, totalShares, pricePerShare);
      
      // Publish subscription event
      pubsub.publish('ASSET_UPDATED', { assetUpdated: asset });
      
      return asset;
    },

    // Marketplace mutations
    createListing: async (_: any, { input }: { input: any }, { sdk }: { sdk: OmniFlowSDK }) => {
      const asset = await sdk.assets.getAsset(input.assetId);
      if (!asset) {
        throw new Error('Asset not found');
      }

      const listingType = input.listingType.toLowerCase() as 'fixed' | 'auction' | 'fractional';
      const listing = await sdk.marketplace.createListing(asset, input.price, listingType, input.duration);
      
      // Publish subscription event
      pubsub.publish('LISTING_CREATED', { listingCreated: listing });
      
      return listing;
    },

    purchaseAsset: async (_: any, { listingId, buyerAddress }: { 
      listingId: string; 
      buyerAddress: string; 
    }, { sdk }: { sdk: OmniFlowSDK }) => {
      const transaction = await sdk.marketplace.purchaseAsset(listingId, buyerAddress);
      
      // Get updated listing and publish subscription event
      const listing = await sdk.marketplace.getListing(listingId);
      if (listing) {
        pubsub.publish('ASSET_PURCHASED', { assetPurchased: listing });
      }
      
      return transaction;
    },

    placeBid: async (_: any, { listingId, bidderAddress, bidAmount }: { 
      listingId: string; 
      bidderAddress: string; 
      bidAmount: string; 
    }, { sdk }: { sdk: OmniFlowSDK }) => {
      const transaction = await sdk.marketplace.placeBid(listingId, bidderAddress, bidAmount);
      
      // Get updated listing and publish subscription event
      const listing = await sdk.marketplace.getListing(listingId);
      if (listing) {
        pubsub.publish('BID_PLACED', { bidPlaced: listing });
      }
      
      return transaction;
    },

    cancelListing: async (_: any, { listingId, sellerAddress }: { 
      listingId: string; 
      sellerAddress: string; 
    }, { sdk }: { sdk: OmniFlowSDK }) => {
      const transaction = await sdk.marketplace.cancelListing(listingId, sellerAddress);
      
      // Get updated listing and publish subscription event
      const listing = await sdk.marketplace.getListing(listingId);
      if (listing) {
        pubsub.publish('LISTING_UPDATED', { listingUpdated: listing });
      }
      
      return transaction;
    },

    updateListingPrice: async (_: any, { listingId, newPrice, sellerAddress }: { 
      listingId: string; 
      newPrice: string; 
      sellerAddress: string; 
    }, { sdk }: { sdk: OmniFlowSDK }) => {
      const listing = await sdk.marketplace.updateListingPrice(listingId, newPrice, sellerAddress);
      
      // Publish subscription event
      pubsub.publish('LISTING_UPDATED', { listingUpdated: listing });
      
      return listing;
    },

    toggleFavorite: async (_: any, { listingId, userAddress }: { 
      listingId: string; 
      userAddress: string; 
    }, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.marketplace.toggleFavorite(listingId, userAddress);
    },

    // DeFi mutations
    stakeAsset: async (_: any, { input }: { input: any }, { sdk }: { sdk: OmniFlowSDK }) => {
      const asset = await sdk.assets.getAsset(input.assetId);
      if (!asset) {
        throw new Error('Asset not found');
      }

      const position = await sdk.defi.stakeAsset(asset, input.poolId, input.amount, input.lockupPeriod);
      
      // Publish subscription event
      pubsub.publish('ASSET_STAKED', { assetStaked: position });
      
      return position;
    },

    unstakeAsset: async (_: any, { positionId }: { positionId: string }, { sdk }: { sdk: OmniFlowSDK }) => {
      const transaction = await sdk.defi.unstakeAsset(positionId);
      
      // Publish subscription event
      pubsub.publish('ASSET_UNSTAKED', { assetUnstaked: { id: positionId } });
      
      return transaction;
    },

    claimRewards: async (_: any, { positionId }: { positionId: string }, { sdk }: { sdk: OmniFlowSDK }) => {
      const transaction = await sdk.defi.claimRewards(positionId);
      
      // Publish subscription event
      pubsub.publish('REWARDS_CLAIMED', { rewardsClaimed: { id: positionId } });
      
      return transaction;
    },

    depositCollateral: async (_: any, { input }: { input: any }, { sdk }: { sdk: OmniFlowSDK }) => {
      const asset = await sdk.assets.getAsset(input.assetId);
      if (!asset) {
        throw new Error('Asset not found');
      }

      return await sdk.defi.depositCollateral(asset, input.protocol, input.amount);
    },

    borrowAgainstCollateral: async (_: any, { input }: { input: any }, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.defi.borrowAgainstCollateral(input.positionId, input.borrowAmount, input.borrowToken);
    },

    calculateYield: async (_: any, { input }: { input: any }, { sdk }: { sdk: OmniFlowSDK }) => {
      const asset = await sdk.assets.getAsset(input.assetId);
      if (!asset) {
        throw new Error('Asset not found');
      }

      return await sdk.defi.calculateYield(asset, input.strategy, input.duration);
    },

    // Bridge mutations
    bridgeAsset: async (_: any, { input }: { input: any }, { sdk }: { sdk: OmniFlowSDK }) => {
      const asset = await sdk.assets.getAsset(input.assetId);
      if (!asset) {
        throw new Error('Asset not found');
      }

      const targetChainId = input.targetChainId.toLowerCase() as ChainId;
      const transfer = await sdk.bridge.bridgeAsset(asset, targetChainId, input.recipient);
      
      // Publish subscription event
      pubsub.publish('BRIDGE_INITIATED', { bridgeInitiated: transfer });
      
      return transfer;
    },

    estimateBridge: async (_: any, { input }: { input: any }, { sdk }: { sdk: OmniFlowSDK }) => {
      const asset = await sdk.assets.getAsset(input.assetId);
      if (!asset) {
        throw new Error('Asset not found');
      }

      const targetChainId = input.targetChainId.toLowerCase() as ChainId;
      return await sdk.bridge.estimateBridge(asset, targetChainId);
    },

    cancelBridgeTransfer: async (_: any, { transferId }: { transferId: string }, { sdk }: { sdk: OmniFlowSDK }) => {
      return await sdk.bridge.cancelBridgeTransfer(transferId);
    },

    // Demo mutations
    loadDemoData: async (_: any, __: any, { sdk }: { sdk: OmniFlowSDK }) => {
      try {
        const [assets, listings, transfers] = await Promise.all([
          sdk.assets.loadDemoAssets(),
          sdk.marketplace.loadDemoListings(),
          sdk.bridge.loadDemoBridgeTransfers(),
        ]);

        return `Demo data loaded successfully: ${assets.length} assets, ${listings.length} listings, ${transfers.length} transfers`;
      } catch (error) {
        throw new Error(`Failed to load demo data: ${error}`);
      }
    },

    simulateOneChainDemo: async (_: any, __: any, { sdk }: { sdk: OmniFlowSDK }) => {
      try {
        const oneChainProvider = sdk.getProvider('onechain');
        if ('simulateDemoDemo' in oneChainProvider) {
          const results = await (oneChainProvider as any).simulateDemoDemo();
          return `OneChain demo completed: ${results.assetsCreated} assets created, ${results.transactionsExecuted} transactions executed, $${results.totalValue} total value`;
        }
        return 'OneChain demo simulation completed';
      } catch (error) {
        throw new Error(`Demo simulation failed: ${error}`);
      }
    },
  },

  Subscription: {
    // Asset subscriptions
    assetCreated: {
      subscribe: () => pubsub.asyncIterator('ASSET_CREATED'),
    },

    marketUpdate: {
      subscribe: () => pubsub.asyncIterator('MARKET_UPDATE'),
    },

    assetTransferred: {
      subscribe: () => pubsub.asyncIterator('ASSET_TRANSFERRED'),
    },

    // Marketplace subscriptions
    stakingPositionCreated: {
      subscribe: () => pubsub.asyncIterator('STAKING_POSITION_CREATED'),
    },

    portfolioUpdated: {
      subscribe: () => pubsub.asyncIterator('PORTFOLIO_UPDATED'),
    },

    assetPurchased: {
      subscribe: () => pubsub.asyncIterator('ASSET_PURCHASED'),
    },

    yieldClaimed: {
      subscribe: () => pubsub.asyncIterator('YIELD_CLAIMED'),
    },

    // DeFi subscriptions
    userActivity: {
      subscribe: () => pubsub.asyncIterator('USER_ACTIVITY'),
    },

    assetUnstaked: {
      subscribe: () => pubsub.asyncIterator('ASSET_UNSTAKED'),
    },

    transactionConfirmed: {
      subscribe: () => pubsub.asyncIterator('TRANSACTION_CONFIRMED'),
    },

    // Bridge subscriptions
    bridgeTransferInitiated: {
      subscribe: () => pubsub.asyncIterator('BRIDGE_TRANSFER_INITIATED'),
    },

    bridgeTransferCompleted: {
      subscribe: () => pubsub.asyncIterator('BRIDGE_TRANSFER_COMPLETED'),
    },

    priceAlert: {
      subscribe: () => pubsub.asyncIterator('PRICE_ALERT'),
    },
  },
};

// Export PubSub instance for use in SDK event handlers
export { pubsub };
