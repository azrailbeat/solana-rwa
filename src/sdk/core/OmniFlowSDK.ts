import { EventEmitter } from 'events';
import { ChainProvider, SDKConfig, Asset, Transaction, ChainId, BridgeTransfer } from './types';
import { OneChainProvider } from '../chains/OneChainProvider';
import { EthereumProvider } from '../chains/EthereumProvider';
import { PolygonProvider } from '../chains/PolygonProvider';
import { BSCProvider } from '../chains/BSCProvider';
import { AssetManager } from '../managers/AssetManager';
import { MarketplaceManager } from '../managers/MarketplaceManager';
import { DeFiManager } from '../managers/DeFiManager';
import { CrossChainBridge } from '../managers/CrossChainBridge';
import { AnalyticsManager } from '../managers/AnalyticsManager';
import { PluginManager } from '../managers/PluginManager';

/**
 * Main OmniFlow SDK class - Entry point for all RWA marketplace interactions
 */
export class OmniFlowSDK extends EventEmitter {
  private config: SDKConfig;
  private providers: Map<ChainId, ChainProvider> = new Map();
  private initialized = false;

  // Core managers
  public assets: AssetManager;
  public marketplace: MarketplaceManager;
  public defi: DeFiManager;
  public bridge: CrossChainBridge;
  public analytics: AnalyticsManager;
  public plugins: PluginManager;

  constructor(config: SDKConfig) {
    super();
    this.config = {
      ...config,
      preferredChain: config.preferredChain || 'onechain', // OneChain-first
      apiEndpoint: config.apiEndpoint || 'https://api.omniflow.io',
      wsEndpoint: config.wsEndpoint || 'wss://ws.omniflow.io',
    };

    // Initialize managers
    this.assets = new AssetManager(this.providers);
    this.marketplace = new MarketplaceManager(this.providers);
    this.defi = new DeFiManager(this.providers);
    this.bridge = new CrossChainBridge(this.providers);
    this.analytics = new AnalyticsManager();
    this.plugins = new PluginManager();
  }

  /**
   * Initialize the SDK with chain providers
   */
  async initialize(): Promise<void> {
    if (this.initialized) return;

    try {
      // Initialize OneChain first (preferred)
      if (this.config.chains.includes('onechain')) {
        const oneChainProvider = new OneChainProvider(this.config);
        await oneChainProvider.initialize();
        this.providers.set('onechain', oneChainProvider);
        this.emit('chainConnected', 'onechain');
      }

      // Initialize other chains
      for (const chainId of this.config.chains) {
        if (chainId === 'onechain') continue; // Already initialized

        let provider: ChainProvider;
        switch (chainId) {
          case 'ethereum':
            provider = new EthereumProvider(this.config);
            break;
          case 'polygon':
            provider = new PolygonProvider(this.config);
            break;
          case 'bsc':
            provider = new BSCProvider(this.config);
            break;
          default:
            throw new Error(`Unsupported chain: ${chainId}`);
        }

        await provider.initialize();
        this.providers.set(chainId, provider);
        this.emit('chainConnected', chainId);
      }

      // Initialize managers (skip if methods don't exist)
      // Most managers don't need explicit initialization

      this.initialized = true;
      this.emit('initialized');
    } catch (error) {
      this.emit('error', error);
      throw error;
    }
  }

  /**
   * Get provider for specific chain
   */
  getProvider(chainId: ChainId): ChainProvider {
    const provider = this.providers.get(chainId);
    if (!provider) {
      throw new Error(`Provider not found for chain: ${chainId}`);
    }
    return provider;
  }

  /**
   * Get preferred provider (OneChain by default)
   */
  getPreferredProvider(): ChainProvider {
    return this.getProvider(this.config.preferredChain);
  }

  /**
   * Get all connected chains
   */
  getConnectedChains(): ChainId[] {
    return Array.from(this.providers.keys());
  }

  /**
   * Switch to different preferred chain
   */
  async switchChain(chainId: ChainId): Promise<void> {
    if (!this.providers.has(chainId)) {
      throw new Error(`Chain ${chainId} not connected`);
    }
    this.config.preferredChain = chainId;
    this.emit('chainSwitched', chainId);
  }

  /**
   * Create a new RWA asset
   */
  async createAsset(assetData: Partial<Asset>): Promise<Asset> {
    return this.assets.createAsset(assetData);
  }

  /**
   * Get asset by ID
   */
  async getAsset(assetId: string, chainId?: ChainId): Promise<Asset | null> {
    return this.assets.getAsset(assetId);
  }

  /**
   * List assets with filtering
   */
  async listAssets(filters?: any): Promise<Asset[]> {
    return this.assets.getAssets(filters);
  }

  /**
   * Execute cross-chain asset transfer
   */
  async transferAsset(
    assetId: string,
    fromChain: ChainId,
    toChain: ChainId,
    recipient: string
  ): Promise<BridgeTransfer> {
    const asset = await this.getAsset(assetId);
    if (!asset) throw new Error('Asset not found');
    return this.bridge.bridgeAsset(asset, toChain, recipient);
  }

  /**
   * Get real-time analytics
   */
  async getAnalytics(type: string, params?: any): Promise<any> {
    // Map generic analytics request to available analytics methods
    if (type === 'dashboard') {
      return this.analytics.getDashboardMetrics(params?.timeRange || '24h');
    }
    if (type === 'user' && params?.userId) {
      return this.analytics.getUserAnalytics(params.userId);
    }
    if (type === 'asset' && params?.assetId) {
      return this.analytics.getAssetAnalytics(params.assetId);
    }
    throw new Error(`Unsupported analytics type: ${type}`);
  }

  /**
   * Subscribe to real-time events
   */
  subscribeToEvents(_eventTypes: string[]): void {
    // Placeholder for real-time subscriptions wiring
  }

  /**
   * Install a plugin
   */
  async installPlugin(pluginManifest: any, code = ''): Promise<void> {
    await this.plugins.installPlugin(pluginManifest, code);
  }

  /**
   * Get SDK configuration
   */
  getConfig(): SDKConfig {
    return { ...this.config };
  }

  /**
   * Update SDK configuration
   */
  updateConfig(updates: Partial<SDKConfig>): void {
    this.config = { ...this.config, ...updates };
    this.emit('configUpdated', this.config);
  }

  /**
   * Get SDK health status
   */
  async getHealth(): Promise<{
    status: 'healthy' | 'degraded' | 'unhealthy';
    chains: Record<ChainId, boolean>;
    services: Record<string, boolean>;
  }> {
    const chains: Record<ChainId, boolean> = {} as any;
    const services: Record<string, boolean> = {};

    // Check chain providers
    for (const [chainId, provider] of Array.from(this.providers.entries())) {
      try {
        chains[chainId] = await provider.isHealthy();
      } catch {
        chains[chainId] = false;
      }
    }

    // Check services (assume healthy if no health check method)
    services.assets = true;
    services.marketplace = true;
    services.yield = true;
    services.bridge = true;
    services.analytics = true;

    const allChainHealthy = Object.values(chains).every(Boolean);
    const allServicesHealthy = Object.values(services).every(Boolean);

    let status: 'healthy' | 'degraded' | 'unhealthy';
    if (allChainHealthy && allServicesHealthy) {
      status = 'healthy';
    } else if (chains.onechain && services.assets && services.marketplace) {
      status = 'degraded'; // Core functionality working
    } else {
      status = 'unhealthy';
    }

    return { status, chains, services };
  }

  /**
   * Cleanup and disconnect
   */
  async disconnect(): Promise<void> {
    // Disconnect all providers
    await Promise.all(
      Array.from(this.providers.values()).map(provider => provider.disconnect())
    );

    // Cleanup managers (skip if methods don't exist)
    // Most managers don't need explicit cleanup

    this.providers.clear();
    this.initialized = false;
    this.emit('disconnected');
  }

  /**
   * Static factory method for quick setup
   */
  static async create(config: SDKConfig): Promise<OmniFlowSDK> {
    const sdk = new OmniFlowSDK(config);
    await sdk.initialize();
    return sdk;
  }

  /**
   * Static method for OneChain-only setup (demo demo)
   */
  static async createOneChainDemo(apiKey: string): Promise<OmniFlowSDK> {
    const config: SDKConfig = {
      apiKey,
      chains: ['onechain'],
      preferredChain: 'onechain',
      environment: 'testnet',
      enableAnalytics: true,
      enableRealTime: true,
    };

    return OmniFlowSDK.create(config);
  }
}
