import { SDKConfig, ChainId, APIResponse } from './core/types';
import { AssetsModule } from './modules/assets';
import { MarketplaceModule } from './modules/marketplace';
import { BridgeModule } from './modules/bridge';

/**
 * Main SolanaFlow SDK class
 */
export class SolanaFlowSDK {
  public assets: AssetsModule;
  public marketplace: MarketplaceModule;
  public bridge: BridgeModule;
  private config: SDKConfig;
  private initialized: boolean = false;

  constructor(config: SDKConfig) {
    this.config = config;
    this.assets = new AssetsModule();
    this.marketplace = new MarketplaceModule();
    this.bridge = new BridgeModule();
  }

  /**
   * Initialize the SDK
   */
  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }

    try {
      // Initialize modules
      console.log('Initializing SolanaFlow SDK...');
      console.log(`Environment: ${this.config.environment}`);
      console.log(`Preferred Chain: ${this.config.preferredChain}`);
      console.log(`Supported Chains: ${this.config.chains.join(', ')}`);

      this.initialized = true;
      console.log('SolanaFlow SDK initialized successfully');
    } catch (error) {
      console.error('Failed to initialize SDK:', error);
      throw error;
    }
  }

  /**
   * Get provider for specific chain
   */
  getProvider(chainId: ChainId): any {
    // Mock provider implementation
    return {
      chainId,
      isConnected: true,
      simulateDemoDemo: async () => ({
        message: `OneChain demo simulation for ${chainId}`,
        timestamp: new Date().toISOString(),
        features: ['RWA Tokenization', 'Cross-chain Bridge', 'DeFi Integration'],
        stats: {
          totalAssets: 150,
          totalValue: '$50M',
          activeUsers: 1200,
        },
      }),
    };
  }

  /**
   * Disconnect and cleanup
   */
  async disconnect(): Promise<void> {
    this.initialized = false;
    console.log('SolanaFlow SDK disconnected');
  }

  /**
   * Get SDK configuration
   */
  getConfig(): SDKConfig {
    return { ...this.config };
  }

  /**
   * Check if SDK is initialized
   */
  isInitialized(): boolean {
    return this.initialized;
  }
}

// Export types and modules
export * from './core/types';
export { AssetsModule } from './modules/assets';
export { MarketplaceModule } from './modules/marketplace';
export { BridgeModule } from './modules/bridge';
