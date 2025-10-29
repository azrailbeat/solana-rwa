import { gql } from 'apollo-server-express';

export const typeDefs = gql`
  scalar DateTime
  scalar BigInt

  enum ChainId {
    ONECHAIN
    ETHEREUM
    POLYGON
    BSC
  }

  enum AssetType {
    REAL_ESTATE
    RENEWABLE_ENERGY
    CARBON_CREDITS
    PRECIOUS_METALS
    COMMODITIES
    BONDS
    STOCKS
    INTELLECTUAL_PROPERTY
    AGRICULTURE
    FORESTRY
    INFRASTRUCTURE
    ART_COLLECTIBLES
  }

  enum AssetStatus {
    ACTIVE
    INACTIVE
    PENDING
  }

  enum ListingType {
    FIXED
    AUCTION
  }

  enum ListingStatus {
    ACTIVE
    SOLD
    CANCELLED
    EXPIRED
  }

  enum DeFiPositionType {
    STAKING
    LENDING
    YIELD_FARMING
  }

  enum DeFiPositionStatus {
    ACTIVE
    COMPLETED
    CANCELLED
  }

  enum BridgeStatus {
    PENDING
    COMPLETED
    FAILED
    CANCELLED
  }

  type AssetAttribute {
    trait_type: String!
    value: String!
  }

  type AssetMetadata {
    name: String!
    description: String
    image: String
    attributes: [AssetAttribute!]
    externalUrl: String
    animationUrl: String
  }

  type ComplianceInfo {
    level: String!
    verifications: [String!]!
    region: String!
  }

  type FractionalInfo {
    enabled: Boolean!
    totalShares: Int!
    availableShares: Int!
    pricePerShare: String!
  }

  type Asset {
    id: ID!
    chainId: ChainId!
    contractAddress: String!
    tokenId: Int!
    type: AssetType!
    name: String!
    description: String!
    value: String!
    currency: String!
    metadata: AssetMetadata!
    owner: String!
    compliance: ComplianceInfo!
    fractional: FractionalInfo!
    status: AssetStatus!
    createdAt: DateTime!
    updatedAt: DateTime!
    transactionHash: String
  }

  type Bid {
    bidder: String!
    amount: String!
    timestamp: DateTime!
    transactionHash: String
  }

  type MarketplaceListing {
    id: ID!
    assetId: String!
    asset: Asset
    chainId: ChainId!
    seller: String!
    buyer: String
    price: String!
    currency: String!
    listingType: ListingType!
    status: ListingStatus!
    createdAt: DateTime!
    updatedAt: DateTime!
    expiresAt: DateTime
    bids: [Bid!]!
    views: Int!
    favorites: Int!
    transactionHash: String
    contractAddress: String
  }

  type RewardsInfo {
    earned: String!
    pending: String!
    claimed: String!
  }

  type CollateralInfo {
    deposited: String!
    healthFactor: String!
    liquidationThreshold: String!
  }

  type BorrowInfo {
    amount: String!
    token: String!
    timestamp: DateTime!
  }

  type DeFiPosition {
    id: ID!
    assetId: String!
    asset: Asset
    chainId: ChainId!
    protocol: String!
    type: DeFiPositionType!
    amount: String!
    apy: String!
    startDate: DateTime!
    endDate: DateTime
    lockupPeriod: Int
    status: DeFiPositionStatus!
    rewards: RewardsInfo
    collateral: CollateralInfo
    borrowed: [BorrowInfo!]
    transactionHash: String
    contractAddress: String
    owner: String
  }

  type StakingPool {
    id: ID!
    name: String!
    protocol: String!
    apy: String!
    tvl: String!
    supportedAssets: [AssetType!]!
    lockupPeriod: Int
    contractAddress: String!
  }

  type YieldStrategy {
    id: ID!
    name: String!
    description: String!
    apy: String!
    risk: String!
    protocols: [String!]!
    supportedAssets: [AssetType!]!
  }

  type BridgeTransfer {
    id: ID!
    assetId: String!
    asset: Asset
    sourceChainId: ChainId!
    targetChainId: ChainId!
    sender: String!
    recipient: String!
    status: BridgeStatus!
    lockTransactionHash: String
    mintTransactionHash: String
    createdAt: DateTime!
    updatedAt: DateTime!
    completedAt: DateTime
    estimatedTime: Int!
    error: String
  }

  type Transaction {
    hash: String!
    chainId: ChainId!
    from: String!
    to: String!
    value: String!
    gasPrice: String!
    gasLimit: String!
    data: String!
    nonce: Int!
    status: String!
  }

  type AssetValuation {
    currentValue: String!
    currency: String!
    lastUpdated: DateTime!
    history: [ValuationHistory!]!
  }

  type ValuationHistory {
    value: String!
    date: DateTime!
  }

  type ComplianceValidation {
    isCompliant: Boolean!
    issues: [String!]!
    recommendations: [String!]!
  }

  type MarketplaceStats {
    totalListings: Int!
    activeListings: Int!
    totalVolume: String!
    averagePrice: String!
    topAssetTypes: [AssetTypeCount!]!
  }

  type AssetTypeCount {
    type: String!
    count: Int!
  }

  type DeFiAnalytics {
    totalValueLocked: String!
    totalRewardsEarned: String!
    activePositions: Int!
    averageAPY: String!
    topProtocols: [ProtocolTVL!]!
  }

  type ProtocolTVL {
    protocol: String!
    tvl: String!
  }

  type BridgeRoute {
    sourceChain: ChainId!
    targetChain: ChainId!
    estimatedTime: Int!
    fee: String!
    supported: Boolean!
  }

  type BridgeEstimation {
    estimatedTime: Int!
    bridgeFee: String!
    gasCost: String!
    totalCost: String!
  }

  type BridgeAnalytics {
    totalTransfers: Int!
    successfulTransfers: Int!
    totalVolume: String!
    averageTime: Float!
    popularRoutes: [RouteCount!]!
  }

  type RouteCount {
    route: String!
    count: Int!
  }

  type YieldCalculation {
    principal: String!
    estimatedYield: String!
    totalReturn: String!
    apy: String!
  }

  input AssetFilter {
    chainId: ChainId
    type: AssetType
    owner: String
    status: AssetStatus
    minValue: Float
    maxValue: Float
  }

  input MarketplaceFilter {
    chainId: ChainId
    seller: String
    listingType: ListingType
    status: ListingStatus
    minPrice: Float
    maxPrice: Float
    assetType: AssetType
  }

  input CreateAssetInput {
    chainId: ChainId!
    type: AssetType!
    name: String!
    description: String!
    value: String!
    currency: String = "USD"
    owner: String!
    image: String
    attributes: [AssetAttributeInput!]
    externalUrl: String
    animationUrl: String
    contractAddress: String
    tokenId: Int
    symbol: String
  }

  input AssetAttributeInput {
    trait_type: String!
    value: String!
  }

  input CreateListingInput {
    assetId: String!
    price: String!
    listingType: ListingType!
    duration: Int
  }

  input StakeAssetInput {
    assetId: String!
    poolId: String!
    amount: String!
    lockupPeriod: Int
  }

  input DepositCollateralInput {
    assetId: String!
    protocol: String!
    amount: String!
  }

  input BorrowInput {
    positionId: String!
    borrowAmount: String!
    borrowToken: String!
  }

  input BridgeAssetInput {
    assetId: String!
    targetChainId: ChainId!
    recipient: String
  }

  input BridgeEstimateInput {
    assetId: String!
    targetChainId: ChainId!
  }

  input CalculateYieldInput {
    assetId: String!
    strategy: String!
    duration: Int!
  }

  type Query {
    # Asset queries
    asset(id: ID!): Asset
    assets(filter: AssetFilter, limit: Int, offset: Int): [Asset!]!
    assetsByType(type: AssetType!): [Asset!]!
    assetsByOwner(owner: String!): [Asset!]!
    assetsByChain(chainId: ChainId!): [Asset!]!
    searchAssets(query: String!): [Asset!]!
    assetValuation(id: ID!): AssetValuation
    validateCompliance(id: ID!): ComplianceValidation

    # Marketplace queries
    listing(id: ID!): MarketplaceListing
    listings(filter: MarketplaceFilter, limit: Int, offset: Int): [MarketplaceListing!]!
    trendingListings(limit: Int = 10): [MarketplaceListing!]!
    recentSales(limit: Int = 10): [MarketplaceListing!]!
    searchListings(query: String!): [MarketplaceListing!]!
    marketplaceStats: MarketplaceStats!

    # DeFi queries
    defiPosition(id: ID!): DeFiPosition
    defiPositions(userAddress: String, limit: Int, offset: Int): [DeFiPosition!]!
    stakingPools: [StakingPool!]!
    yieldStrategies: [YieldStrategy!]!
    defiAnalytics: DeFiAnalytics!

    # Bridge queries
    bridgeTransfer(id: ID!): BridgeTransfer
    bridgeTransfers(userAddress: String, limit: Int, offset: Int): [BridgeTransfer!]!
    supportedRoutes: [BridgeRoute!]!
    bridgeAnalytics: BridgeAnalytics!
  }

  type Mutation {
    # Asset mutations
    createAsset(input: CreateAssetInput!): Asset!
    transferAsset(id: ID!, toAddress: String!): Transaction!
    enableFractionalOwnership(id: ID!, totalShares: Int!, pricePerShare: String!): Asset!

    # Marketplace mutations
    createListing(input: CreateListingInput!): MarketplaceListing!
    purchaseAsset(listingId: ID!, buyerAddress: String!): Transaction!
    placeBid(listingId: ID!, bidderAddress: String!, bidAmount: String!): Transaction!
    cancelListing(listingId: ID!, sellerAddress: String!): Transaction!
    updateListingPrice(listingId: ID!, newPrice: String!, sellerAddress: String!): MarketplaceListing!
    toggleFavorite(listingId: ID!, userAddress: String!): Boolean!

    # DeFi mutations
    stakeAsset(input: StakeAssetInput!): DeFiPosition!
    unstakeAsset(positionId: ID!): Transaction!
    claimRewards(positionId: ID!): Transaction!
    depositCollateral(input: DepositCollateralInput!): DeFiPosition!
    borrowAgainstCollateral(input: BorrowInput!): Transaction!
    calculateYield(input: CalculateYieldInput!): YieldCalculation!

    # Bridge mutations
    bridgeAsset(input: BridgeAssetInput!): BridgeTransfer!
    estimateBridge(input: BridgeEstimateInput!): BridgeEstimation!
    cancelBridgeTransfer(transferId: ID!): Transaction!

    # Demo mutations for demos
    loadDemoData: String!
    simulateOneChainDemo: String!
  }

  type Subscription {
    # Real-time asset updates
    assetCreated: Asset!
    assetUpdated: Asset!
    assetTransferred: Asset!

    # Real-time marketplace updates
    listingCreated: MarketplaceListing!
    listingUpdated: MarketplaceListing!
    assetPurchased: MarketplaceListing!
    bidPlaced: MarketplaceListing!

    # Real-time DeFi updates
    assetStaked: DeFiPosition!
    assetUnstaked: DeFiPosition!
    rewardsClaimed: DeFiPosition!

    # Real-time bridge updates
    bridgeInitiated: BridgeTransfer!
    bridgeCompleted: BridgeTransfer!
    bridgeFailed: BridgeTransfer!
  }
`;
